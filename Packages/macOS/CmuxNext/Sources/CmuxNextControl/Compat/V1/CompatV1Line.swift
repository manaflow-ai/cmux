import Foundation

/// One v1 text command: `verb arg… [--key=value|--key value|--flag] [-- tail…]`,
/// shell-style quoting (the CLI shell-quotes every token).
struct CompatV1Line: Sendable {
    let verb: String
    let positional: [String]
    let options: [String: String]
    /// Tokens after a bare `--`.
    let tail: [String]

    init(_ raw: String) {
        let tokens = Self.tokenize(raw)
        verb = tokens.first?.lowercased() ?? ""
        var positional: [String] = []
        var options: [String: String] = [:]
        var tail: [String] = []
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                tail = Array(tokens[(index + 1)...])
                break
            }
            if token.hasPrefix("--"), token.count > 2 {
                let body = token.dropFirst(2)
                if let equals = body.firstIndex(of: "=") {
                    options[String(body[..<equals]).lowercased()] = String(body[body.index(after: equals)...])
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    options[body.lowercased()] = tokens[index + 1]
                    index += 1
                } else {
                    options[body.lowercased()] = ""
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
        self.positional = positional
        self.options = options
        self.tail = tail
    }

    func option(_ name: String) -> String? {
        guard let value = options[name], !value.isEmpty else { return nil }
        return value
    }

    func has(_ flag: String) -> Bool { options[flag] != nil }

    /// Positional tokens from `index` on, joined by spaces.
    func rest(after index: Int) -> String {
        positional.count > index ? positional[index...].joined(separator: " ") : ""
    }

    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                inToken = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                inToken = true
            } else if character.isWhitespace {
                if inToken { tokens.append(current) }
                current = ""
                inToken = false
            } else {
                current.append(character)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
