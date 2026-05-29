import Foundation

public enum HermesAgentCodexEnvironment {
    public static let defaultProvider = "custom"
    public static let codexResponsesAPIMode = "codex_responses"
    public static let codexBaseURLEnvironmentKey = "HERMES_CODEX_BASE_URL"
    public static let customBaseURLEnvironmentKey = "CUSTOM_BASE_URL"

    public static func argumentsWithDefaultProvider(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var hasProviderOverride = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--provider", index + 1 < arguments.count {
                hasProviderOverride = true
                result.append(argument)
                let provider = arguments[index + 1]
                result.append(provider == "openai-codex" ? defaultProvider : provider)
                index += 2
                continue
            }
            if argument.hasPrefix("--provider=") {
                hasProviderOverride = true
                let provider = String(argument.dropFirst("--provider=".count))
                result.append(provider == "openai-codex" ? "--provider=\(defaultProvider)" : argument)
            } else {
                result.append(argument)
            }
            index += 1
        }
        return hasProviderOverride ? result : ["--provider", defaultProvider] + result
    }

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

    public static func customBaseURL(fromOpenAIBaseURL rawValue: String) -> String? {
        guard let components = normalizedHTTPComponents(from: rawValue) else {
            return nil
        }
        guard !hostMatches(components.host, hostSuffix: "api.openai.com") else { return nil }
        return normalizedURLString(from: components)
    }

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
