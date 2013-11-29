module MongodbFulltextSearch::Mixins

  extend ActiveSupport::Concern

  included do

    cattr_accessor :fulltext_search_options

    self.fulltext_search_options = {}

    if MongodbFulltextSearch.mongoid?
      (class << self; self; end).class_eval do
        create_indexes = instance_method :create_indexes
        define_method :create_indexes do
          create_indexes.bind(self).call
          fulltext_search_options.values.each do |options|
            if options[:model].respond_to? :create_indexes
              options[:model].send :create_indexes
            end
          end
        end
      end
    end

  end

  module ClassMethods

    def fulltext_search_in(*args)

      options = args.last.is_a?(Hash) ? args.pop : {}

      if options.has_key? :index
        collection_name = (options.delete :index).to_sym
      else
        count = fulltext_search_options.count
        collection_name = "fulltext_search_index_#{collection.name}_#{count}".to_sym
      end

      if args.empty?
        options[:attributes] = [:to_s]
      else
        options[:attributes] = args
      end

      if MongodbFulltextSearch.mongoid?
        options[:model] = Class.new {
          include Mongoid::Document
          store_in collection: collection_name
          index({
            :source       => 1,
            'counts.word' => 1
          })
          field :source , :type => String
          field :counts , :type => Array
        }
      elsif MongodbFulltextSearch.mongomapper?
        options[:model] = Class.new {
          include MongoMapper::Document
          set_collection_name collection_name
          ensure_index([
            [ :source       , 1 ],
            [ 'counts.word' , 1 ]
          ])
          key :source , String
          key :counts , Array
        }
      end

      fulltext_search_options[collection_name] = options

      attr_accessor :fulltext_search_score

      before_save :update_in_fulltext_search_indexes

      before_destroy :remove_from_fulltext_search_indexes

    end

    def fulltext_search(query, options = {})

      options = {
        :exact         => true,
        :limit         => 20,
        :offset        => 0,
        :return_scores => false
      }.merge options

      results = []

      if query.is_a? String

        words = MongodbFulltextSearch.words_for query

        unless words.empty?

          queries = []; words.each do |word|
            if !!options[:exact]
              queries << { 'counts.word' => word }
            else
              queries << { 'counts.word' => { '$regex' => Regexp.escape(word) } }
            end
          end

          limit = options[:limit].to_i

          pipeline = [
              { '$match'   => { '$and' => queries } },
              { '$unwind'  => '$counts' },
              { '$match'   => { '$or' => queries } },
              { '$sort'    => { 'source' => 1 } },
              { '$group'   => {
                  '_id'    => { 'source' => '$source' },
                  'score'  => { '$sum' => '$counts.count' }
              } },
              { '$sort'    => { 'score' => -1 } },
              { '$limit'   => limit }
          ]

          skip = options[:offset].to_i * limit

          pipeline << { '$skip' => skip } if skip > 0
          pipeline << { '$project' => { 'score' => 1 } }

          if options.has_key? :index
            collection_name = options[:index]
          else
            if fulltext_search_options.count == 1
              collection_name = fulltext_search_options.keys.first
            else
              raise ArgumentError, 'index not specified', caller
            end
          end

          aggregate = MongodbFulltextSearch.mongo_session(self).command(
            :aggregate => collection_name.to_s,
            :pipeline  => pipeline
          )

          scores = {}; aggregate['result'].each do |result|
            scores[result['_id']['source']] = result['score']
          end

          unless scores.empty?
            if options[:return_scores]
              results = scores
            else
              find(scores.keys).each do |result|
                result.fulltext_search_score = scores[result._id.to_s]
                results << result
              end
              results.sort_by! { |result| -result.fulltext_search_score }
            end
          end

        end

      end

      results

    end

  end

  private

  def update_in_fulltext_search_indexes

    fulltext_search_options.each do |collection_name, options|

      if MongodbFulltextSearch.mongoid?
        index = options[:model].find_or_initialize_by :source => _id.to_s
      elsif MongodbFulltextSearch.mongomapper?
        index = options[:model].find_or_initialize_by_source _id.to_s
      end

      index.counts = []

      values = []; options[:attributes].each do |attribute|
        if respond_to? attribute.to_sym
          value_array = send(attribute.to_sym)
          value_array = [value_array] if value_array.is_a? String
          if value_array.is_a? Array
            value_array.each do |value|
              values << value if value.is_a? String
            end
          end
        end
      end

      unless values.nil?
        temp = {}; values.each do |value|
          MongodbFulltextSearch.words_for(value).each do |word|
            temp[word]  = 0 if temp[word].nil?
            temp[word] += 1
          end
        end
        temp.sort.each do |word, count|
          index.counts << { :word => word, :count => count }
        end
      end

      index.save

    end

  end

  def remove_from_fulltext_search_indexes
    fulltext_search_options.values.each do |options|
      if MongodbFulltextSearch.mongoid?
        index = options[:model].where :source => _id.to_s
      elsif MongodbFulltextSearch.mongomapper?
        index = options[:model].find_by_source _id.to_s
      end
      index.destroy unless index.nil?
    end
  end

end
