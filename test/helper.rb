require 'rubygems'
require 'bundler/setup'
require 'zlib'
require 'benchmark'
require 'faker'
require 'minitest/spec'
require 'minitest/autorun'
require 'minitest/reporters'
MiniTest::Unit.runner = MiniTest::SuiteRunner.new
MiniTest::Unit.runner.reporters << MiniTest::Reporters::SpecReporter.new

require 'active_record'
require 'activerecord-import'
require 'active_record_inline_schema'

# require 'logger'
# ActiveRecord::Base.logger = Logger.new($stdout)
# ActiveRecord::Base.logger.level = Logger::DEBUG

class Pet < ActiveRecord::Base
  col :name
  col :gender
  col :good, :type => :boolean
  col :lovability, :type => :float
  col :morning_walk_time, :type => :datetime
  col :zipped_biography, :type => :binary
  col :tag_number, :type => :integer
  col :birthday, :type => :date
  col :home_address, :type => :text
  add_index :name, :unique => true
end

require 'upsert'

MiniTest::Spec.class_eval do
  def self.shared_examples
    @shared_examples ||= {}
  end

  def lotsa_records
    @records ||= begin
      memo = []
      names = []
      50.times do
        names << Faker::Name.name
      end
      200.times do
        selector = ActiveSupport::OrderedHash.new
        selector[:name] = names.sample(1).first
        document = {
          :lovability => BigDecimal.new(rand(1e11), 2),
          :tag_number => rand(1e8),
          :good => true,
          :birthday => Time.at(rand * Time.now.to_i).to_date,
          :morning_walk_time => Time.at(rand * Time.now.to_i),
          :home_address => Faker::Address.street_address,
          :zipped_biography => Upsert.binary(Zlib::Deflate.deflate(Faker::Lorem.paragraphs(10).join("\n\n"), Zlib::BEST_SPEED))
        }
        memo << [selector, document]
      end
      memo
    end
  end

  def assert_same_result(records, &blk)
    blk.call(records)
    ref1 = Pet.order(:name).all.map { |pet| pet.attributes.except('id') }
    
    Pet.delete_all

    upsert = Upsert.new connection, :pets
    upsert.multi do |xxx|
      records.each do |selector, document|
        xxx.row(selector, document)
      end
    end
    ref2 = Pet.order(:name).all.map { |pet| pet.attributes.except('id') }
    ref2.must_equal ref1
  end

  def assert_creates(model, expected_records)
    expected_records.each do |conditions|
      model.where(conditions).count.must_equal 0
    end
    yield
    expected_records.each do |conditions|
      model.where(conditions).count.must_equal 1
    end
  end

  def assert_faster_than(competition, records, &blk)
    # dry run
    blk.call records
    Pet.delete_all
    sleep 1
    # --
    
    ar_time = Benchmark.realtime { blk.call(records) }

    Pet.delete_all
    sleep 1

    upsert_time = Benchmark.realtime do
      upsert = Upsert.new connection, :pets
      upsert.multi do |xxx|
        records.each do |selector, document|
          xxx.row(selector, document)
        end
      end
    end
    upsert_time.must_be :<, ar_time
    $stderr.puts "   Upsert was #{((ar_time - upsert_time) / ar_time * 100).round}% faster than #{competition}"
  end
end

module MiniTest::Spec::SharedExamples
  def shared_examples_for(desc, &block)
    MiniTest::Spec.shared_examples[desc] = block
  end

  def it_also(desc)
    self.instance_eval do
      MiniTest::Spec.shared_examples[desc].call
    end
  end
end

Object.class_eval { include(MiniTest::Spec::SharedExamples) }
Dir[File.expand_path("../shared/*.rb", __FILE__)].each do |path|
  require path
end
