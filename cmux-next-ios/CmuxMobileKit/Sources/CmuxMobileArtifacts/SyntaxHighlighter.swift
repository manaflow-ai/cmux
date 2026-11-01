import SwiftUI

/// A small tokenizer: comments, strings, numbers, keywords, types, HTML tags. Linear in the
/// line: one pass marks each character's role, then runs of one role become one attribute run.
struct SyntaxHighlighter {
    static let keywordColor = Color(red: 0.99, green: 0.37, blue: 0.64)
    static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.36)
    static let commentColor = Color(red: 0.42, green: 0.47, blue: 0.53)
    static let numberColor = Color(red: 0.82, green: 0.75, blue: 0.43)
    static let typeColor = Color(red: 0.36, green: 0.85, blue: 0.95)
    static let tagColor = Color(red: 0.36, green: 0.85, blue: 0.95)

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "match", "fn", "pub", "use", "impl", "mut", "self", "Self", "static", "public", "private", "true",
        "false", "nil", "None", "Some", "async", "await", "try", "guard", "in", "where", "const", "type", "def",
        "from", "export", "function", "new", "package", "name", "version", "edition", "mod", "crate", "as",
    ]

    enum Role: UInt8 {
        case plain, keyword, string, comment, number, type, tag

        var color: Color? {
            switch self {
            case .plain: nil
            case .keyword: SyntaxHighlighter.keywordColor
            case .string: SyntaxHighlighter.stringColor
            case .comment: SyntaxHighlighter.commentColor
            case .number: SyntaxHighlighter.numberColor
            case .type: SyntaxHighlighter.typeColor
            case .tag: SyntaxHighlighter.tagColor
            }
        }
    }

    /// Every line of `text`, split once and highlighted.
    static func highlightLines(_ text: String, language: String) -> [AttributedString] {
        text.components(separatedBy: "\n").map { highlight($0, language: language) }
    }

    static func highlight(_ line: String, language: String) -> AttributedString {
        guard !line.isEmpty else { return AttributedString(line) }
        let characters = Array(line)
        return attributed(characters, roles: roles(characters, language: language))
    }

    /// Each character's role.
    static func roles(_ characters: [Character], language: String) -> [Role] {
        if language == "html" || language == "md" {
            return markupRoles(characters, language: language)
        }
        var roles = [Role](repeating: .plain, count: characters.count)
        let commentPrefix: [Character] = ["py", "sh", "toml", "yml", "yaml", "rb"].contains(language) ? ["#"] : ["/", "/"]
        func hasPrefix(_ prefix: [Character], at index: Int) -> Bool {
            index + prefix.count <= characters.count && characters[index..<index + prefix.count].elementsEqual(prefix)
        }
        func mark(_ start: Int, _ end: Int, _ role: Role) {
            for i in start..<end { roles[i] = role }
        }
        var index = 0
        while index < characters.count {
            if hasPrefix(commentPrefix, at: index) || hasPrefix(["/", "/", "/"], at: index) {
                mark(index, characters.count, .comment)
                break
            }
            let character = characters[index]
            if character == "\"" || character == "'" && language != "rs" {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, characters.count)
                mark(index, end, .string)
                index = end
            } else if character.isNumber {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" { end += 1 }
                mark(index, end, .number)
                index = end
            } else if character.isLetter || character == "_" || character == "#" || character == "@" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                if keywords.contains(word) || word.hasPrefix("#") || word.hasPrefix("@") {
                    mark(index, end, .keyword)
                } else if let first = word.first, first.isUppercase {
                    mark(index, end, .type)
                }
                index = end
            } else {
                index += 1
            }
        }
        return roles
    }

    private static func markupRoles(_ characters: [Character], language: String) -> [Role] {
        var roles = [Role](repeating: .plain, count: characters.count)
        if language == "md" {
            let line = String(characters)
            let role: Role = line.hasPrefix("#") ? .keyword
                : line.hasPrefix("```") || line.hasPrefix("    ") ? .string
                : line.hasPrefix(">") ? .comment : .plain
            return [Role](repeating: role, count: characters.count)
        }
        var index = 0
        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end] != ">" { end += 1 }
            end = min(end + 1, characters.count)
            for i in index..<end { roles[i] = .tag }
            // Attribute values inside the tag.
            var quote = index
            while quote < end {
                if characters[quote] == "\"" {
                    var close = quote + 1
                    while close < end, characters[close] != "\"" { close += 1 }
                    for i in quote..<min(close + 1, end) { roles[i] = .string }
                    quote = close + 1
                } else {
                    quote += 1
                }
            }
            index = end
        }
        return roles
    }

    /// One attribute run per stretch of one role.
    static func attributed(_ characters: [Character], roles: [Role]) -> AttributedString {
        var result = AttributedString()
        var start = 0
        while start < characters.count {
            var end = start + 1
            while end < characters.count, roles[end] == roles[start] { end += 1 }
            var piece = AttributedString(String(characters[start..<end]))
            if let color = roles[start].color { piece.foregroundColor = color }
            result.append(piece)
            start = end
        }
        return result
    }
}
