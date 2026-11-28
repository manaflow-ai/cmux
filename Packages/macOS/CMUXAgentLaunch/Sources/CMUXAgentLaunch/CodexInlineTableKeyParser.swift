import Foundation

/// Extracts top-level inline-table keys without treating values as keys.
///
/// Unsupported syntax returns nil so permission recovery can preserve the
/// explicit override rather than guess about its meaning.
struct CodexInlineTableKeyParser {
    /// Returns direct table keys while skipping quoted and nested value contents.
    func parse(_ value: String) -> Set<String>? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "{", value.last == "}" else { return nil }
        let characters = Array(value.dropFirst().dropLast())
        var quote: Character?
        var escaped = false
        var nesting: [Character] = []
        var start = 0
        var entries: [String] = []
        for (index, character) in characters.enumerated() {
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "{": nesting.append(character)
            case "]": guard nesting.popLast() == "[" else { return nil }
            case "}": guard nesting.popLast() == "{" else { return nil }
            case "," where nesting.isEmpty:
                entries.append(String(characters[start..<index]))
                start = index + 1
            default: break
            }
        }
        guard quote == nil, nesting.isEmpty else { return nil }
        entries.append(String(characters[start...]))
        if entries.count == 1, entries[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        var keys = Set<String>()
        for entry in entries {
            guard let key = assignmentKey(entry) else { return nil }
            keys.insert(key)
        }
        return keys
    }

    /// Decodes a direct assignment key; unrecognized key syntax stays unknown.
    private func assignmentKey(_ entry: String) -> String? {
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        var quote: Character?
        var escaped = false
        for index in entry.indices {
            let character = entry[index]
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if activeQuote == "\"", character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character }
            guard character == "=", quote == nil else { continue }
            let key = entry[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry[entry.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            if key.first == "\"" || key.first == "'" {
                return quotedKey(key)
            }
            guard key.unicodeScalars.allSatisfy({
                $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
            }) else { return nil }
            return key
        }
        return nil
    }

    /// Decodes single-line TOML basic or literal keys, including Unicode escapes.
    ///
    /// TOML basic strings require scalar escapes, not JSON surrogate pairs.
    /// Escape rules: https://toml.io/en/v1.1.0#string
    private func quotedKey(_ key: String) -> String? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count >= 2, let delimiter = scalars.first,
              scalars.last == delimiter else { return nil }
        let end = scalars.count - 1
        var index = 1
        var decoded = ""
        while index < end {
            let scalar = scalars[index]
            index += 1
            if scalar == "\\", delimiter == "\"" {
                guard index < end else { return nil }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "b": decoded.unicodeScalars.append("\u{8}")
                case "t": decoded.unicodeScalars.append("\t")
                case "n": decoded.unicodeScalars.append("\n")
                case "f": decoded.unicodeScalars.append("\u{C}")
                case "r": decoded.unicodeScalars.append("\r")
                case "e": decoded.unicodeScalars.append("\u{1B}")
                case "\"", "\\": decoded.unicodeScalars.append(escape)
                case "x", "u", "U":
                    let digits = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                    guard index + digits <= end else { return nil }
                    var codePoint: UInt32 = 0
                    for character in scalars[index..<(index + digits)] {
                        let digit: UInt32
                        switch character.value {
                        case 48...57: digit = character.value - 48
                        case 65...70: digit = character.value - 65 + 10
                        case 97...102: digit = character.value - 97 + 10
                        default: return nil
                        }
                        codePoint = (codePoint << 4) | digit
                    }
                    guard let value = Unicode.Scalar(codePoint) else { return nil }
                    decoded.unicodeScalars.append(value)
                    index += digits
                default: return nil
                }
            } else {
                guard scalar != delimiter,
                      scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) else {
                    return nil
                }
                decoded.unicodeScalars.append(scalar)
            }
        }
        return decoded
    }
}
