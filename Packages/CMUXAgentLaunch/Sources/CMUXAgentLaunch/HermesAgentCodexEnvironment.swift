import Foundation

public enum HermesAgentCodexEnvironment {
    public static let defaultProvider = "custom"
    public static let codexBaseURLEnvironmentKey = "HERMES_CODEX_BASE_URL"
    public static let customBaseURLEnvironmentKey = "CUSTOM_BASE_URL"

    public static func argumentsWithDefaultProvider(_ arguments: [String]) -> [String] {
        guard !containsProviderOverride(arguments) else { return arguments }
        return ["--provider", defaultProvider] + arguments
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

    public static func codexBaseURL(fromChatGPTBaseURL rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return nil
        }
        let withoutTrailingSlash = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !withoutTrailingSlash.isEmpty else { return nil }
        if withoutTrailingSlash.lowercased().hasSuffix("/codex") {
            return withoutTrailingSlash
        }
        return withoutTrailingSlash + "/codex"
    }

    public static func customBaseURL(fromOpenAIBaseURL rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return nil
        }
        let withoutTrailingSlash = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !withoutTrailingSlash.isEmpty else { return nil }
        guard !hostMatches(withoutTrailingSlash, hostSuffix: "api.openai.com") else { return nil }
        return withoutTrailingSlash
    }

    public static func customBaseURL(fromChatGPTBaseURL rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return nil
        }
        let withoutTrailingSlash = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !withoutTrailingSlash.isEmpty else { return nil }
        guard !hostMatches(withoutTrailingSlash, hostSuffix: "chatgpt.com"),
              !hostMatches(withoutTrailingSlash, hostSuffix: "chat.openai.com") else { return nil }

        guard var components = URLComponents(string: withoutTrailingSlash) else {
            return nil
        }
        let path = components.path
        if path == "/backend-api" || path.hasPrefix("/backend-api/") {
            components.path = "/v1"
            components.query = nil
            components.fragment = nil
            return components.string?.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        return nil
    }

    private static func containsProviderOverride(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument == "--provider" || argument.hasPrefix("--provider=")
        }
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

    private static func hostMatches(_ rawURL: String, hostSuffix: String) -> Bool {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased() else {
            return false
        }
        let suffix = hostSuffix.lowercased()
        return host == suffix || host.hasSuffix("." + suffix)
    }
}
