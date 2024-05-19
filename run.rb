# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails"
  # If you want to test against edge Rails replace the previous line with this:
  # gem "rails", github: "rails/rails", branch: "main"

  gem "sqlite3", "~> 1.4"
  gem 'graphql-batch'
  gem "rspec-rails"
end

require "active_record"
require "action_controller/railtie"
require "logger"

class TestApp < Rails::Application
  config.root = __dir__
  config.hosts << "example.org"
  config.secret_key_base = "secret_key_base"

  config.logger = Logger.new($stdout)
  Rails.logger  = config.logger

  routes.draw do
    post "/graphql" => "graphql#execute"
  end
end

# This connection will do for database-independent bug reports.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
  end
end

class Post < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

# https://github.com/Shopify/graphql-batch/blob/main/examples/record_loader.rb
class RecordLoader < GraphQL::Batch::Loader
  def initialize(model, column: model.primary_key, **active_record_methods)
    super()
    @model = model
    @column = column.to_s
    @column_type, @attr_fields = column_type_and_attr_fields
    @active_record_methods = active_record_methods
  end

  def load(key)
    super(@column_type.cast(key))
  end

  def perform(keys)
    records_hash = query(keys).each_with_object({}) do |record, obj|
      column_value = column_value_from(record)
      obj[column_value] ||= []
      obj[column_value] << record
    end

    keys.each { |key| fulfill(key, (records_hash[key] || [])) }
  end

  private

  def column_value_from(record)
    column_value = record
    @attr_fields.each do |attr_field|
      column_value = column_value.public_send(attr_field)
    end
    column_value
  end

  def column_type_and_attr_fields
    return [@model.type_for_attribute(@column), [@column]] unless @model.column_for_attribute(@column).is_a?(ActiveRecord::ConnectionAdapters::NullColumn)

    association_table, association_column = @column.split('.')
    association = @model.reflections.values.find { |rv| rv.plural_name == association_table }

    raise ArgumentError, "No association from #{association_table} on #{@model}" if association.nil?

    [association.klass.type_for_attribute(association_column), [association.name, association_column]]
  end

  def query(keys)
    scope = @model
    scope = scope.where(@where) if @where
    scope.where(@column => keys)
  end
end

class CommentType < GraphQL::Schema::Object
  field :id, Int
  field :post_id, Int
end

class PostType < GraphQL::Schema::Object
  field :id, Int
  field :latest_comment, CommentType

  def latest_comment
    RecordLoader.for(Comment, column: :post_id).load(object.id).then(&:last)
  end
end

class TestQuery < GraphQL::Schema::Object
  field :posts, [PostType]

  def posts
    Post.all
  end
end

class TestSchema < GraphQL::Schema
  query(TestQuery)
  use GraphQL::Batch
end

class GraphqlController < ActionController::API
  def execute
    query = params[:params][:query]

    result = TestSchema.execute(query, variables: {}, context: {}, operation_name: params[:operationName]).to_h
    pp result
    render json: result
  end
end

require "rack/test"
require "minitest/autorun"

class Test < Minitest::Test
  include Rack::Test::Methods

  def test_first
    3.times do
      post = Post.create!
      3.times do
        post.comments.create!
      end
    end

    query = <<~QUERY
      query {
        posts {
          id
          latestComment {
            id
            postId
          }
        }
      }
    QUERY
    post "/graphql", params: { query: }, as: :json
  end

  private
    def app
      Rails.application
    end
end
