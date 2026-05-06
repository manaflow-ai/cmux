import Foundation

public enum NodeOptionsSupport {
    public static let restoreModuleFilename = "restore-node-options.cjs"

    public static func claudeRestoreDirectory(
        homePath: String?,
        appSupportDirectory: URL? = nil
    ) -> URL {
        let trimmedHome = homePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSupport: URL
        if let trimmedHome, !trimmedHome.isEmpty {
            appSupport = URL(fileURLWithPath: trimmedHome, isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        } else if let appSupportDirectory {
            appSupport = appSupportDirectory
        } else {
            appSupport = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("node-options", isDirectory: true)
    }

    public static func requirePath(_ path: String) -> String {
        quoteTokenIfNeeded(path)
    }

    public static func tokens(_ rawValue: String?) -> [String] {
        guard let rawValue else { return [] }

        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in rawValue {
            if let activeQuote = quote {
                if escaping {
                    current.append(character)
                    escaping = false
                    continue
                }
                if character == "\\" {
                    escaping = true
                    continue
                }
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    public static func joinedTokens(_ tokens: [String]) -> String {
        tokens.map(quoteTokenIfNeeded).joined(separator: " ")
    }

    public static func isCmuxRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard url.lastPathComponent == restoreModuleFilename else {
            return false
        }
        let components = url.pathComponents
        return components.suffix(3) == ["cmux", "node-options", restoreModuleFilename]
            || components.suffix(2) == ["cmux-claude-node-options", restoreModuleFilename]
    }

    public static func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    public static func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    public static func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size=4096" {
            return true
        }
        return token == "--max-old-space-size"
            && index + 1 < tokens.count
            && tokens[index + 1] == "4096"
    }

    public static func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count,
              tokens[index] == "--max-old-space-size",
              index + 1 < tokens.count else {
            return 1
        }
        return 2
    }

    private static func quoteTokenIfNeeded(_ value: String) -> String {
        let charactersRequiringQuotes = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\\\""))
        guard value.rangeOfCharacter(from: charactersRequiringQuotes) != nil else {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
