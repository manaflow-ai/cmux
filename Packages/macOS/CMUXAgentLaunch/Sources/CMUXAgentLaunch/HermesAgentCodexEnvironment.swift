import Foundation

/// Utilities for mapping Codex configuration into Hermes Agent's custom provider settings.
public enum HermesAgentCodexEnvironment {
    /// The Hermes provider name used for Codex-compatible custom endpoints.
    public static let defaultProvider = "custom"
    /// The Hermes API mode used when talking to Codex-compatible responses endpoints.
    public static let codexResponsesAPIMode = "codex_responses"
    /// Environment key that carries the ChatGPT Codex backend URL for Hermes.
    public static let codexBaseURLEnvironmentKey = "HERMES_CODEX_BASE_URL"
    /// Environment key that carries the OpenAI-compatible custom base URL for Hermes.
    public static let customBaseURLEnvironmentKey = "CUSTOM_BASE_URL"

    /// Rewrites stale `openai-codex` Hermes provider arguments to the current custom provider.
    public static func argumentsByReplacingOpenAICodexProvider(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--provider", index + 1 < arguments.count {
                result.append(argument)
                let provider = arguments[index + 1]
                result.append(provider == "openai-codex" ? defaultProvider : provider)
                index += 2
                continue
            }
            if argument.hasPrefix("--provider=") {
                let provider = String(argument.dropFirst("--provider=".count))
                result.append(provider == "openai-codex" ? "--provider=\(defaultProvider)" : argument)
            } else {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    /// Returns arguments that include a Hermes provider, preserving an explicit provider when present.
    public static func argumentsWithDefaultProvider(_ arguments: [String]) -> [String] {
        let result = argumentsByReplacingOpenAICodexProvider(arguments)
        if hasProviderOverride(result) {
            return result
        }
        return ["--provider", defaultProvider] + result
    }

    private static func hasProviderOverride(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--provider", index + 1 < arguments.count {
                return true
            }
            if argument.hasPrefix("--provider=") {
                return true
            }
            index += 1
        }
        return false
    }

    /// Adds default Hermes Codex endpoint environment values from the user's Codex config.
    public static func applyingDefaultCodexBaseURL(
        to environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let configContent = codexConfigContent(
            environment: environment,
            ambientEnvironment: ambientEnvironment
        ) else {
            return environment
        }
        var result = environment
        if normalized(result[codexBaseURLEnvironmentKey]) == nil,
           let codexBaseURL = codexBaseURL(fromCodexConfigContent: configContent) {
            result[codexBaseURLEnvironmentKey] = codexBaseURL
        }
        if normalized(result[customBaseURLEnvironmentKey]) == nil,
           let customBaseURL = customBaseURL(fromCodexConfigContent: configContent) {
            result[customBaseURLEnvironmentKey] = customBaseURL
        }
        return result
    }

    /// Reads the default Codex backend URL from the user's Codex config.
    public static func defaultCodexBaseURL(
        environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let content = codexConfigContent(
            environment: environment,
            ambientEnvironment: ambientEnvironment
        ) else { return nil }
        return codexBaseURL(fromCodexConfigContent: content)
    }

    /// Reads the default OpenAI-compatible custom URL from the user's Codex config.
    public static func defaultCustomBaseURL(
        environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let content = codexConfigContent(
            environment: environment,
            ambientEnvironment: ambientEnvironment
        ) else { return nil }
        return customBaseURL(fromCodexConfigContent: content)
    }

    /// Reads the default Codex model from the user's Codex config.
    public static func defaultCodexModel(
        environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let content = codexConfigContent(
            environment: environment,
            ambientEnvironment: ambientEnvironment
        ) else { return nil }
        return codexModel(fromCodexConfigContent: content)
    }

    /// Extracts a Hermes Codex backend URL from Codex TOML config content.
    public static func codexBaseURL(fromCodexConfigContent content: String) -> String? {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                return nil
            }
            guard let value = tomlStringValue(forKey: "chatgpt_base_url", in: line) else {
                continue
            }
            return codexBaseURL(fromChatGPTBaseURL: value)
        }
        return nil
    }

    /// Extracts a Hermes custom provider base URL from Codex TOML config content.
    public static func customBaseURL(fromCodexConfigContent content: String) -> String? {
        var fallbackChatGPTBaseURL: String?
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                break
            }
            if let value = tomlStringValue(forKey: "openai_base_url", in: line),
               let baseURL = customBaseURL(fromOpenAIBaseURL: value) {
                return baseURL
            }
            if let value = tomlStringValue(forKey: "chatgpt_base_url", in: line),
               let baseURL = customBaseURL(fromChatGPTBaseURL: value) {
                fallbackChatGPTBaseURL = baseURL
            }
        }
        return fallbackChatGPTBaseURL
    }

    /// Extracts a Codex model name from Codex TOML config content.
    public static func codexModel(fromCodexConfigContent content: String) -> String? {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                return nil
            }
            guard let value = tomlStringValue(forKey: "model", in: line) else {
                continue
            }
            return normalized(value)
        }
        return nil
    }

    /// Converts a ChatGPT backend URL into the Hermes Codex backend URL.
    public static func codexBaseURL(fromChatGPTBaseURL rawValue: String) -> String? {
        guard var components = normalizedHTTPComponents(from: rawValue) else {
            return nil
        }
        if components.path.lowercased().hasSuffix("/codex") {
            return normalizedURLString(from: components)
        }
        components.path = components.path.isEmpty ? "/codex" : components.path + "/codex"
        return normalizedURLString(from: components)
    }

    /// Returns a custom Hermes base URL from a non-OpenAI `openai_base_url` value.
    public static func customBaseURL(fromOpenAIBaseURL rawValue: String) -> String? {
        guard let components = normalizedHTTPComponents(from: rawValue) else {
            return nil
        }
        guard !hostMatches(components.host, hostSuffix: "api.openai.com") else { return nil }
        return normalizedURLString(from: components)
    }

    /// Returns a custom Hermes base URL from a non-OpenAI ChatGPT backend URL.
    public static func customBaseURL(fromChatGPTBaseURL rawValue: String) -> String? {
        guard var components = normalizedHTTPComponents(from: rawValue) else {
            return nil
        }
        guard !hostMatches(components.host, hostSuffix: "chatgpt.com"),
              !hostMatches(components.host, hostSuffix: "chat.openai.com") else { return nil }

        if components.path == "/backend-api" || components.path.hasPrefix("/backend-api/") {
            components.path = "/v1"
            return normalizedURLString(from: components)
        }
        return nil
    }

    private static func codexConfigPath(
        environment: [String: String],
        ambientEnvironment: [String: String]
    ) -> String? {
        let rawCodexHome = normalized(environment["CODEX_HOME"])
            ?? normalized(ambientEnvironment["CODEX_HOME"])
        let codexHome: String
        if let rawCodexHome {
            codexHome = (rawCodexHome as NSString).expandingTildeInPath
        } else if let home = normalized(environment["HOME"]) ?? normalized(ambientEnvironment["HOME"]) {
            codexHome = ((home as NSString).expandingTildeInPath as NSString).appendingPathComponent(".codex")
        } else {
            codexHome = ("~/.codex" as NSString).expandingTildeInPath
        }
        return (codexHome as NSString).appendingPathComponent("config.toml")
    }

    private static func codexConfigContent(
        environment: [String: String],
        ambientEnvironment: [String: String]
    ) -> String? {
        guard let configPath = codexConfigPath(environment: environment, ambientEnvironment: ambientEnvironment) else {
            return nil
        }
        return try? String(contentsOfFile: configPath, encoding: .utf8)
    }

    private static func tomlStringValue(forKey key: String, in line: String) -> String? {
        let withoutComment = stripTomlComment(from: line).trimmingCharacters(in: .whitespaces)
        guard !withoutComment.isEmpty,
              let equalsIndex = withoutComment.firstIndex(of: "=") else {
            return nil
        }
        let keyPart = String(withoutComment[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        guard keyPart == key || keyPart == "\"\(key)\"" || keyPart == "'\(key)'" else {
            return nil
        }
        let valuePart = String(withoutComment[withoutComment.index(after: equalsIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return parseTomlQuotedString(valuePart)
    }

    private static func parseTomlQuotedString(_ value: String) -> String? {
        guard let first = value.first else { return nil }
        if first == "'" {
            guard let end = value.dropFirst().firstIndex(of: "'") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end])
        }
        guard first == "\"" else { return nil }
        var result = ""
        var isEscaped = false
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if isEscaped {
                switch character {
                case "\"", "\\": result.append(character)
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func stripTomlComment(from line: String) -> String {
        var result = ""
        var quote: Character?
        var isEscaped = false
        for character in line {
            if let activeQuote = quote {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "#" {
                break
            }
            if character == "\"" || character == "'" {
                quote = character
            }
            result.append(character)
        }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedHTTPComponents(from rawValue: String) -> URLComponents? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = normalized(components.host),
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = components.path.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        return components
    }

    private static func normalizedURLString(from components: URLComponents) -> String? {
        components.string?.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func hostMatches(_ rawHost: String?, hostSuffix: String) -> Bool {
        guard let host = normalized(rawHost)?.lowercased() else {
            return false
        }
        let suffix = hostSuffix.lowercased()
        return host == suffix || host.hasSuffix("." + suffix)
    }
}
