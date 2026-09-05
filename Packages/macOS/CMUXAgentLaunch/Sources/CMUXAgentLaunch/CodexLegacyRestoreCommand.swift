import Foundation

/// The inspectable subset of old, literal shell-only Codex resume commands.
///
/// Parsing never executes shell code or rewrites the original command. An
/// absolute inline CODEX_HOME is required because login-shell startup can
/// override inherited environment. Complex commands deliberately fail closed.
public struct CodexLegacyRestoreCommand: Sendable {
    /// Literal argv, including the Codex executable.
    public let arguments: [String]
    /// Inline assignments that determine the actual account.
    public let environment: [String: String]

    /// Recognizes a literal resume bound to the expected session and account.
    /// - Parameters:
    ///   - command: Original shell command, not evaluated by this parser.
    ///   - sessionID: Validated checkpoint UUID; a different command binding is rejected.
    public init?(command: String, sessionID: String) {
        guard let words = Self.literalWords(command), UUID(uuidString: sessionID) != nil else { return nil }
        var index = 0
        var environment: [String: String] = [:]
        if words.first == "exec" { index += 1 }
        if index < words.count, ["env", "/usr/bin/env"].contains(words[index]) { index += 1 }
        while index < words.count, let equals = words[index].firstIndex(of: "=") {
            let name = String(words[index][..<equals])
            guard ["CODEX_HOME", "HOME"].contains(name) else { return nil }
            environment[name] = String(words[index][words[index].index(after: equals)...])
            index += 1
        }
        guard let home = environment["CODEX_HOME"], home.hasPrefix("/"),
              index < words.count, (words[index] as NSString).lastPathComponent == "codex" else { return nil }
        let arguments = Array(words[index...])
        var positionals: [String] = []
        index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument != "--" else { return nil }
            if argument.hasPrefix("-") {
                index += AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: AgentLaunchSanitizer.codexPolicy)
            } else {
                positionals.append(argument)
                index += 1
            }
        }
        guard positionals.count == 2, positionals[0] == "resume",
              UUID(uuidString: positionals[1]) == UUID(uuidString: sessionID) else { return nil }
        self.arguments = arguments
        self.environment = environment
    }

    /// Accepts only literal POSIX words; expansion, redirection and command lists are not a safe scope.
    private static func literalWords(_ command: String) -> [String]? {
        guard command.utf8.count <= 65_536 else { return nil }
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in command {
            guard !character.isNewline, character != "\0" else { return nil }
            if escaped {
                word.append(character)
                escaped = false
            } else if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if character == "\\" {
                // Double-quoted backslash rules differ from unquoted ones.
                guard quote == nil else { return nil }
                escaped = true
                started = true
            } else if character == "$" || character == "`" {
                return nil
            } else if let currentQuote = quote {
                if character == currentQuote { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else if ";&|<>(){}[]*?!~#".contains(character) {
                return nil
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }
}
