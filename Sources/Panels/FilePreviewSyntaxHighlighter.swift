import AppKit

/// Applies lightweight, language-aware coloring to editable file preview text.
struct FilePreviewSyntaxHighlighter {
    /// Keeps per-keystroke recoloring bounded while large files retain the fast plain-text path.
    static let maximumHighlightedUTF16Length = 256 * 1024

    let language: FilePreviewSyntaxLanguage
    let baseColor: NSColor
    let appearance: NSAppearance

    func apply(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let text = textStorage.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let palette = Palette(appearance: appearance)

        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        if language != .plainText, fullRange.length <= Self.maximumHighlightedUTF16Length {
            let candidateStringRanges = ranges(for: stringPattern, in: text, fullRange: fullRange)
            let commentSearchText = textMasking(candidateStringRanges, in: text)
            let commentRanges = ranges(
                for: commentPattern,
                in: commentSearchText,
                fullRange: fullRange
            )
            apply(color: palette.comment, to: commentRanges, in: textStorage)

            let stringRanges = candidateStringRanges.filter { candidate in
                !commentRanges.contains(where: { Self.contains(candidate.location, in: $0) })
            }
            apply(color: palette.string, to: stringRanges, in: textStorage)
            let protectedRanges = commentRanges + stringRanges

            apply(
                color: palette.number,
                to: ranges(for: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, in: text, fullRange: fullRange),
                excluding: protectedRanges,
                in: textStorage
            )
            apply(
                color: palette.keyword,
                to: ranges(for: keywordPattern, in: text, fullRange: fullRange),
                excluding: protectedRanges,
                in: textStorage
            )
            apply(
                color: palette.type,
                to: ranges(for: #"\b[A-Z][A-Za-z0-9_]*\b"#, in: text, fullRange: fullRange),
                excluding: protectedRanges,
                in: textStorage
            )
            for rule in structuralRules {
                apply(
                    color: palette.color(for: rule.role),
                    to: ranges(
                        for: rule.pattern,
                        captureGroup: rule.captureGroup,
                        in: text,
                        fullRange: fullRange
                    ),
                    excluding: rule.canOverlapProtectedRanges ? [] : protectedRanges,
                    in: textStorage
                )
            }
        }

        textStorage.endEditing()
        var typingAttributes = textView.typingAttributes
        typingAttributes[.foregroundColor] = baseColor
        textView.typingAttributes = typingAttributes
        textView.insertionPointColor = baseColor
    }

    private var commentPattern: String {
        switch language {
        case .python, .ruby, .shell, .yaml, .toml, .configuration:
            return #"(?m)#.*$"#
        case .sql:
            return #"(?ms)--.*?$|/\*.*?\*/"#
        case .html:
            return #"(?s)<!--.*?-->"#
        case .plainText, .markdown, .json:
            return #"(?!)"#
        default:
            return #"(?ms)//.*?$|/\*.*?\*/"#
        }
    }

    private var stringPattern: String {
        switch language {
        case .markdown:
            return #"(?s)`[^`]*`"#
        case .plainText:
            return #"(?!)"#
        default:
            return #"(?s)\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        }
    }

    private var keywordPattern: String {
        let keywords: [String]
        switch language {
        case .swift:
            keywords = ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .javascript, .typescript:
            keywords = ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .python:
            keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .shell:
            keywords = ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "select", "then", "until", "while"]
        case .rust:
            keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .go:
            keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .cFamily, .java, .kotlin:
            keywords = ["abstract", "auto", "boolean", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "fun", "goto", "if", "implements", "import", "in", "instanceof", "int", "interface", "long", "namespace", "new", "null", "object", "override", "package", "private", "protected", "public", "return", "short", "signed", "static", "struct", "super", "switch", "this", "throw", "throws", "true", "try", "typedef", "typename", "union", "unsigned", "using", "val", "var", "virtual", "void", "volatile", "when", "while"]
        case .sql:
            keywords = ["ALL", "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "COMMIT", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FALSE", "FROM", "FULL", "GROUP", "HAVING", "IN", "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "TRUE", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE", "WITH"]
        case .ruby:
            keywords = ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case .php:
            keywords = ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or", "private", "protected", "public", "readonly", "require", "return", "static", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield"]
        case .json:
            keywords = ["false", "null", "true"]
        default:
            keywords = []
        }
        guard !keywords.isEmpty else { return #"(?!)"# }
        let alternation = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let caseInsensitivePrefix = language == .sql ? "(?i)" : ""
        return "\(caseInsensitivePrefix)\\b(?:\(alternation))\\b"
    }

    private var structuralRules: [Rule] {
        switch language {
        case .swift, .javascript, .typescript, .python, .rust, .go, .cFamily, .java, .kotlin, .ruby, .php:
            return [Rule(pattern: #"\b(?:actor|class|enum|func|function|interface|protocol|struct|trait|type|def|fn)\s+([A-Za-z_][A-Za-z0-9_]*)"#, captureGroup: 1, role: .type)]
        case .json:
            return [Rule(pattern: #"\"(?:\\.|[^\"\\])*\"\s*(?=:)"#, role: .type, canOverlapProtectedRanges: true)]
        case .configuration, .toml, .yaml:
            return [Rule(pattern: #"(?m)^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*(?=[:=])"#, captureGroup: 1, role: .type)]
        case .html:
            return [Rule(pattern: #"<\/?\s*([A-Za-z][A-Za-z0-9:-]*)"#, captureGroup: 1, role: .keyword)]
        case .css:
            return [Rule(pattern: #"(?m)^\s*([A-Za-z-]+)\s*(?=:)"#, captureGroup: 1, role: .type)]
        case .markdown:
            return [
                Rule(pattern: #"(?m)^#{1,6}\s+.*$"#, role: .keyword),
                Rule(pattern: #"\[[^\]]+\]\([^\)]+\)"#, role: .type)
            ]
        case .sql:
            return [Rule(pattern: #"(?i)\b(?:FROM|INTO|JOIN|TABLE|UPDATE)\s+([A-Za-z_][A-Za-z0-9_.]*)"#, captureGroup: 1, role: .type)]
        case .plainText, .shell:
            return []
        }
    }

    private func ranges(
        for pattern: String,
        captureGroup: Int = 0,
        in text: String,
        fullRange: NSRange
    ) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard captureGroup < match.numberOfRanges else { return nil }
            let range = match.range(at: captureGroup)
            return range.location == NSNotFound ? nil : range
        }
    }

    private func apply(
        color: NSColor,
        to ranges: [NSRange],
        excluding excludedRanges: [NSRange] = [],
        in textStorage: NSTextStorage
    ) {
        for range in ranges where !excludedRanges.contains(where: { Self.overlaps(range, $0) }) {
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private func textMasking(_ ranges: [NSRange], in text: String) -> String {
        let masked = NSMutableString(string: text)
        let source = text as NSString
        for range in ranges.reversed() {
            let units = Array(source.substring(with: range).utf16).map { unit in
                unit == 10 || unit == 13 ? unit : UInt16(32)
            }
            masked.replaceCharacters(in: range, with: String(decoding: units, as: UTF16.self))
        }
        return masked as String
    }

    private static func overlaps(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func contains(_ location: Int, in range: NSRange) -> Bool {
        location >= range.location && location < NSMaxRange(range)
    }

    private enum Role {
        case keyword
        case type
    }

    private struct Rule {
        let pattern: String
        var captureGroup = 0
        let role: Role
        var canOverlapProtectedRanges = false
    }

    private struct Palette {
        let comment: NSColor
        let keyword: NSColor
        let number: NSColor
        let string: NSColor
        let type: NSColor

        init(appearance: NSAppearance) {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            comment = isDark
                ? NSColor(calibratedRed: 0.49, green: 0.57, blue: 0.50, alpha: 1)
                : NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.35, alpha: 1)
            keyword = isDark
                ? NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.75, alpha: 1)
                : NSColor(calibratedRed: 0.65, green: 0.16, blue: 0.47, alpha: 1)
            number = isDark
                ? NSColor(calibratedRed: 0.49, green: 0.73, blue: 1.00, alpha: 1)
                : NSColor(calibratedRed: 0.13, green: 0.37, blue: 0.72, alpha: 1)
            string = isDark
                ? NSColor(calibratedRed: 0.67, green: 0.82, blue: 0.46, alpha: 1)
                : NSColor(calibratedRed: 0.26, green: 0.49, blue: 0.10, alpha: 1)
            type = isDark
                ? NSColor(calibratedRed: 0.47, green: 0.82, blue: 0.84, alpha: 1)
                : NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.52, alpha: 1)
        }

        func color(for role: Role) -> NSColor {
            switch role {
            case .keyword: keyword
            case .type: type
            }
        }
    }
}
