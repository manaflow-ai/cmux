/// A forward-only cursor over a config file's characters, shared by the TOML and Lua readers.
struct CharacterScanner {
    private let characters: [Character]
    private(set) var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    var isAtEnd: Bool { index >= characters.count }
    var peek: Character? { index < characters.count ? characters[index] : nil }

    func peek(offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    mutating func advance(_ count: Int = 1) {
        index = min(index + count, characters.count)
    }

    mutating func skipSpaces() {
        while let char = peek, char == " " || char == "\t" || char == "\r" { advance() }
    }

    mutating func skipWhitespaceAndNewlines() {
        while let char = peek, char.isWhitespace { advance() }
    }

    mutating func skipWhitespaceNewlinesAndComments() {
        while let char = peek {
            if char.isWhitespace {
                advance()
            } else if char == "#" {
                skipLine()
            } else {
                break
            }
        }
    }

    mutating func skipLine() {
        while let char = peek, char != "\n" { advance() }
        advance()
    }

    /// Reads a `"..."` (with backslash escapes) or `'...'` string starting at the cursor.
    mutating func readQuoted() -> String? {
        guard let quote = peek, quote == "\"" || quote == "'" else { return nil }
        advance()
        var value = ""
        while let char = peek {
            advance()
            if char == quote { return value }
            if char == "\\", quote == "\"", let escaped = peek {
                advance()
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: value.append(escaped)
                }
                continue
            }
            if char == "\n" { return value }
            value.append(char)
        }
        return value
    }
}
