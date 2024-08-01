# frozen_string_literal: true

require "httparty"
require "numo/narray"
require "faiss"
require "matrix"
require "io/console"
require "mistral-ai"
require "zeitwerk"
require "dotenv/load"
require "byebug"
require_relative "simple_rag/version"
require_relative "simple_rag/cli"

loader = Zeitwerk::Loader.for_gem
loader.setup

module SimpleRag
  class Error < StandardError; end

  class Engine
    def run_mistral(client, user_message, model: "mistral-medium-latest")
      messages = [{role: "user", content: user_message}]
      chat_response = client.chat_completions({model: model, messages: messages})
      chat_response.dig("choices", 0, "message", "content")  # .choices[0].message.content
    end

    DEFAULT_URL = "http://www.paulgraham.com/worked.html"

    def prompt_user_for_url
      print "Specify a URL to an HTML document you would like to ask questions of (Default: What I Worked On by Paul Graham): "
      input_url = STDIN.gets.chomp
      input_url.empty? ? DEFAULT_URL : input_url
    end

    def valid_url?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      false
    end

    def get_url
      url = prompt_user_for_url
      until valid_url?(url)
        puts "The URL provided is invalid. Please try again."
        url = prompt_user_for_url
      end
      url
    end

    def run
      url = get_url

      # Setup LLM of choice
      api_key = ENV["MISTRAL_AI_KEY"] || STDIN.getpass("Type your API Key: ")
      raise "Missing API Key" unless api_key

      client = Mistral.new(
        credentials: {api_key: api_key},
        options: {server_sent_events: true}
      )

      # Indexing
      index_instance = SimpleRag::Index.new(client)
      text = index_instance.load("https://raw.githubusercontent.com/run-llama/llama_index/main/docs/docs/examples/data/paul_graham/paul_graham_essay.txt")
      # text = "Ruby and AI will take over the world. - Landon"
      chunks = index_instance.chunk(text)
      text_embeddings = index_instance.embed_chunks(chunks)
      index = index_instance.save(text_embeddings)

      # Retrieval
      retrieve_instance = SimpleRag::Retrieve.new(client)
      query = retrieve_instance.query("What were the two main things the author worked on before college?")
      retrieve_instance.save_index(index)
      retrieve_instance.save_chunks(chunks)
      question_embedding = retrieve_instance.embed_query
      retrieved_chunks = retrieve_instance.similarity_search(question_embedding, 2)

      # Generation
      prompt = SimpleRag::Generate.new.prompt(query, retrieved_chunks)

      puts run_mistral(client, prompt)
    end
  end
end
