import Foundation
import Security

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    enum Provider: String, CaseIterable, Identifiable {
        case gemini
        case gpt
        case claude
        case openrouter
        case deepseek
        case qwen
        case minimax

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gemini:
                return "Gemini"
            case .gpt:
                return "GPT"
            case .claude:
                return "Claude"
            case .openrouter:
                return "OpenRouter"
            case .deepseek:
                return "DeepSeek"
            case .qwen:
                return "Qwen"
            case .minimax:
                return "MiniMax"
            }
        }

        var apiKeyDefaultsKey: String {
            switch self {
            case .gemini:
                return "chatProviderGeminiAPIKey"
            case .gpt:
                return "chatProviderOpenAIAPIKey"
            case .claude:
                return "chatProviderAnthropicAPIKey"
            case .openrouter:
                return "chatProviderOpenRouterAPIKey"
            case .deepseek:
                return "chatProviderDeepSeekAPIKey"
            case .qwen:
                return "chatProviderQwenAPIKey"
            case .minimax:
                return "chatProviderMiniMaxAPIKey"
            }
        }

        var defaultModel: String {
            switch self {
            case .gemini:
                return "gemini-2.0-flash"
            case .gpt:
                return "gpt-4o-mini"
            case .claude:
                return "claude-3-5-sonnet-latest"
            case .openrouter:
                return "openai/gpt-4o-mini"
            case .deepseek:
                return "deepseek-chat"
            case .qwen:
                return "qwen-plus"
            case .minimax:
                return "MiniMax-M2.7"
            }
        }

        var modelDefaultsKey: String {
            "chatProviderModel.\(rawValue)"
        }

        var modelOptions: [String] {
            switch self {
            case .gemini:
                return ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"]
            case .gpt:
                return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]
            case .claude:
                return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-opus-latest"]
            case .openrouter:
                return ["openai/gpt-4o-mini", "openai/gpt-4o", "anthropic/claude-3.5-sonnet", "google/gemini-flash-1.5"]
            case .deepseek:
                return ["deepseek-chat", "deepseek-reasoner"]
            case .qwen:
                return ["qwen-plus", "qwen-max", "qwen-turbo", "qwen3-max", "qwen3-coder-plus"]
            case .minimax:
                return ["MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1", "MiniMax-M2"]
            }
        }

        var apiKeyPlaceholder: String {
            switch self {
            case .gemini:
                return "AIza..."
            case .gpt:
                return "sk-..."
            case .claude:
                return "sk-ant-..."
            case .openrouter:
                return "sk-or-..."
            case .deepseek:
                return "sk-..."
            case .qwen:
                return "sk-..."
            case .minimax:
                return "eyJ..."
            }
        }
    }

    struct Message: Identifiable, Equatable {
        let id: UUID
        let role: Role
        var content: String

        enum Role: String {
            case user
            case assistant
        }

        init(role: Role, content: String) {
            self.id = UUID()
            self.role = role
            self.content = content
        }
    }

    private static let selectedProviderDefaultsKey = "chatSelectedProvider"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var streamingError: String?
    @Published var selectedProvider: Provider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.selectedProviderDefaultsKey)
        }
    }

    private var streamTask: Task<Void, Never>?
    private var currentStreamID: UUID = UUID()

    init() {
        let rawProvider = UserDefaults.standard.string(forKey: Self.selectedProviderDefaultsKey) ?? Provider.claude.rawValue
        selectedProvider = Provider(rawValue: rawProvider) ?? .claude
        migrateLegacyAnthropicKeyIfNeeded()
    }

    var apiKey: String {
        get { apiKey(for: selectedProvider) }
        set { setApiKey(newValue, for: selectedProvider) }
    }

    var selectedModel: String {
        get { model(for: selectedProvider) }
        set { setModel(newValue, for: selectedProvider) }
    }

    var hasApiKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func apiKey(for provider: Provider) -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.cmux.chat.apikey",
            kSecAttrAccount: provider.apiKeyDefaultsKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func setApiKey(_ key: String, for provider: Provider) {
        let data = key.data(using: .utf8) ?? Data()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.cmux.chat.apikey",
            kSecAttrAccount: provider.apiKeyDefaultsKey,
        ]
        if key.isEmpty {
            SecItemDelete(query as CFDictionary)
        } else {
            let attributes: [CFString: Any] = [kSecValueData: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData] = data
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
        objectWillChange.send()
    }

    func model(for provider: Provider) -> String {
        let saved = UserDefaults.standard.string(forKey: provider.modelDefaultsKey) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultModel : saved
    }

    func setModel(_ model: String, for provider: Provider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? provider.defaultModel : trimmed, forKey: provider.modelDefaultsKey)
        objectWillChange.send()
    }

    func modelOptions(for provider: Provider) -> [String] {
        let selected = model(for: provider)
        guard !provider.modelOptions.contains(selected) else { return provider.modelOptions }
        return [selected] + provider.modelOptions
    }

    func clearMessages() {
        messages = []
        streamingError = nil
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        guard hasApiKey else {
            streamingError = String(localized: "chatPanel.error.missingApiKey", defaultValue: "Choose a provider and enter an API key in chat settings.")
            return
        }

        streamingError = nil
        messages.append(Message(role: .user, content: trimmed))

        isStreaming = true
        let sendMessages = messages
        let provider = selectedProvider
        let key = apiKey
        let model = selectedModel
        let streamID = UUID()
        currentStreamID = streamID

        streamTask = Task {
            var assistantContent = ""
            var appendedAssistant = false

            do {
                let request = try Self.buildRequest(messages: sendMessages, provider: provider, apiKey: key, model: model)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw ChatAPIError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    var body = ""
                    for try await line in bytes.lines { body += line }
                    throw ChatAPIError.httpError(http.statusCode, body)
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data: ") else { continue }
                    let data = String(line.dropFirst(6))
                    if data == "[DONE]" { break }
                    guard let chunk = Self.parseSSEChunk(data, provider: provider) else { continue }

                    assistantContent += chunk
                    if !appendedAssistant {
                        messages.append(Message(role: .assistant, content: assistantContent))
                        appendedAssistant = true
                    } else if let idx = messages.indices.last {
                        messages[idx].content = assistantContent
                    }
                }

                if !appendedAssistant {
                    messages.append(Message(role: .assistant, content: assistantContent))
                }
            } catch {
                if !Task.isCancelled {
                    streamingError = (error as? ChatAPIError)?.errorDescription ?? error.localizedDescription
                }
                if assistantContent.isEmpty && appendedAssistant {
                    messages.removeLast()
                }
            }

            // Only clear streaming state if this is still the active stream.
            if streamID == currentStreamID {
                isStreaming = false
            }
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func migrateLegacyAnthropicKeyIfNeeded() {
        let legacyKey = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        guard !legacyKey.isEmpty, apiKey(for: .claude).isEmpty else { return }
        setApiKey(legacyKey, for: .claude)
        UserDefaults.standard.removeObject(forKey: "anthropicAPIKey")
    }

    private static func buildRequest(messages: [Message], provider: Provider, apiKey: String, model: String) throws -> URLRequest {
        switch provider {
        case .gemini:
            return try buildGeminiRequest(messages: messages, apiKey: apiKey, model: model)
        case .gpt:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                messages: messages,
                apiKey: apiKey,
                model: model,
                extraHeaders: [:]
            )
        case .claude:
            return try buildClaudeRequest(messages: messages, apiKey: apiKey, model: model)
        case .openrouter:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                messages: messages,
                apiKey: apiKey,
                model: model,
                extraHeaders: [
                    "HTTP-Referer": "https://cmux.local",
                    "X-Title": "cmux"
                ]
            )
        case .deepseek:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.deepseek.com/chat/completions")!,
                messages: messages,
                apiKey: apiKey,
                model: model,
                extraHeaders: [:]
            )
        case .qwen:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                messages: messages,
                apiKey: apiKey,
                model: model,
                extraHeaders: [:]
            )
        case .minimax:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.minimax.io/v1/chat/completions")!,
                messages: messages,
                apiKey: apiKey,
                model: model,
                extraHeaders: [:]
            )
        }
    }

    private static func buildOpenAICompatibleRequest(
        url: URL,
        messages: [Message],
        apiKey: String,
        model: String,
        extraHeaders: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func buildClaudeRequest(messages: [Message], apiKey: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func buildGeminiRequest(messages: [Message], apiKey: String, model: String) throws -> URLRequest {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "contents": messages.map {
                [
                    "role": $0.role == .assistant ? "model" : "user",
                    "parts": [["text": $0.content]]
                ]
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseSSEChunk(_ data: String, provider: Provider) -> String? {
        guard let json = decodeJSONObject(data) else { return nil }

        switch provider {
        case .gemini:
            return parseGeminiChunk(json)
        case .gpt, .openrouter, .deepseek, .qwen, .minimax:
            return parseOpenAICompatibleChunk(json)
        case .claude:
            return parseClaudeChunk(json)
        }
    }

    private static func decodeJSONObject(_ data: String) -> [String: Any]? {
        guard let jsonData = data.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    }

    private static func parseOpenAICompatibleChunk(_ json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let text = delta["content"] as? String else {
            return nil
        }
        return text
    }

    private static func parseClaudeChunk(_ json: [String: Any]) -> String? {
        guard let type = json["type"] as? String,
              type == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    private static func parseGeminiChunk(_ json: [String: Any]) -> String? {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}

enum ChatAPIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "chatPanel.error.invalidResponse", defaultValue: "Invalid API response")
        case .httpError(let code, let body):
            let message = String(body.prefix(200))
            return String(localized: "chatPanel.error.http", defaultValue: "API error (\(code)): \(message)")
        }
    }
}
