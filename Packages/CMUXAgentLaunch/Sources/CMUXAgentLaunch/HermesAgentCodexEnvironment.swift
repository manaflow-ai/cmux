import Foundation

public enum HermesAgentCodexEnvironment {
    public static let defaultProvider = "openai-codex"
    public static let codexBaseURLEnvironmentKey = "HERMES_CODEX_BASE_URL"

    public static func argumentsWithDefaultProvider(_ arguments: [String]) -> [String] {
        guard !containsProviderOverride(arguments) else { return arguments }
        return ["--provider", defaultProvider] + arguments
    }

    public static func applyingDefaultCodexBaseURL(
        to environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard normalized(environment[codexBaseURLEnvironmentKey]) == nil,
              let baseURL = defaultCodexBaseURL(
                environment: environment,
                ambientEnvironment: ambientEnvironment
              ) else {
            return environment
        }
        var result = environment
        result[codexBaseURLEnvironmentKey] = baseURL
        return result
    }

    public static func defaultCodexBaseURL(
        environment: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let configPath = codexConfigPath(environment: environment, ambientEnvironment: ambientEnvironment),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        return codexBaseURL(fromCodexConfigContent: content)
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
}
