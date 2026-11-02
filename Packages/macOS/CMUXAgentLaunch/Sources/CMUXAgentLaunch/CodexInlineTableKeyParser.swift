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
            if key.first == "\"" {
                return (try? JSONSerialization.jsonObject(with: Data(key.utf8), options: .fragmentsAllowed)) as? String
            }
            if key.first == "'", key.last == "'" {
                let literal = String(key.dropFirst().dropLast())
                return literal.contains("'") ? nil : literal
            }
            guard key.unicodeScalars.allSatisfy({
                $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
            }) else { return nil }
            return key
        }
        return nil
    }
}
