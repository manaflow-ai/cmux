import AppKit
import Foundation

/// Pure Swift regex-based syntax highlighting for code files.
/// Applies colored NSAttributedString to NSTextView content.
/// Zero external dependencies.
enum SyntaxHighlighter {

    // MARK: - Color Palettes (VS Code-inspired)

    private struct DarkPalette {
        static let keyword = NSColor(red: 0.337, green: 0.612, blue: 0.839, alpha: 1.0)   // #569CD6
        static let string = NSColor(red: 0.808, green: 0.569, blue: 0.471, alpha: 1.0)     // #CE9178
        static let comment = NSColor(red: 0.416, green: 0.600, blue: 0.333, alpha: 1.0)    // #6A9955
        static let number = NSColor(red: 0.710, green: 0.808, blue: 0.659, alpha: 1.0)     // #B5CEA8
        static let type = NSColor(red: 0.306, green: 0.788, blue: 0.690, alpha: 1.0)       // #4EC9B0
        static let attribute = NSColor(red: 0.863, green: 0.863, blue: 0.506, alpha: 1.0)  // #DCDCAE
        static let text = NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1.0)       // #D4D4D4
    }

    private struct LightPalette {
        static let keyword = NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)          // blue
        static let string = NSColor(red: 0.639, green: 0.082, blue: 0.082, alpha: 1.0)     // #A31515
        static let comment = NSColor(red: 0.0, green: 0.502, blue: 0.0, alpha: 1.0)        // green
        static let number = NSColor(red: 0.098, green: 0.463, blue: 0.824, alpha: 1.0)     // #1977D2
        static let type = NSColor(red: 0.165, green: 0.525, blue: 0.459, alpha: 1.0)       // #267F75
        static let attribute = NSColor(red: 0.502, green: 0.502, blue: 0.0, alpha: 1.0)    // olive
        static let text = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)             // black
    }

    // MARK: - Keywords by language family

    private static let cFamilyKeywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "class",
        "struct", "enum", "protocol", "extension", "guard", "switch", "case", "default",
        "break", "continue", "do", "try", "catch", "throw", "throws", "async", "await",
        "public", "private", "internal", "fileprivate", "open", "static", "final",
        "override", "init", "deinit", "self", "super", "nil", "true", "false",
        "const", "function", "export", "from", "new", "this", "typeof", "instanceof",
        "void", "null", "undefined", "interface", "type", "implements", "extends",
        "package", "fn", "pub", "mod", "use", "crate", "impl", "trait", "where",
        "mut", "ref", "match", "loop", "in", "as", "is", "val", "def", "object",
        "int", "float", "double", "char", "bool", "string", "any", "never",
        "abstract", "virtual", "volatile", "extern", "inline", "template", "typename",
        "namespace", "using", "include", "define", "ifdef", "endif", "pragma",
    ]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
        "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue",
        "and", "or", "not", "in", "is", "None", "True", "False", "lambda", "yield",
        "global", "nonlocal", "del", "assert", "async", "await", "self", "print",
    ]

    // MARK: - Public API

    /// Apply syntax highlighting and return an NSAttributedString.
    static func highlight(_ text: String, fileExtension: String, isDark: Bool) -> NSAttributedString {
        let p = isDark ? darkColors() : lightColors()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: p.text]

        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Order matters: comments and strings should override keywords
        let keywords = keywordsForExtension(fileExtension)

        // 1. Keywords (whole words)
        if !keywords.isEmpty {
            let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            applyPattern(keywordPattern, to: result, in: fullRange, color: p.keyword)
        }

        // 2. Types (capitalized identifiers like String, URL, Bool)
        applyPattern("\\b[A-Z][a-zA-Z0-9_]*\\b", to: result, in: fullRange, color: p.type)

        // 3. Numbers
        applyPattern("\\b\\d+\\.?\\d*\\b", to: result, in: fullRange, color: p.number)

        // 4. Decorators / attributes (@MainActor, @Published, @objc)
        applyPattern("@[a-zA-Z_][a-zA-Z0-9_]*", to: result, in: fullRange, color: p.attribute)

        // 5. Strings (double-quoted and single-quoted) — override keywords inside strings
        applyPattern("\"(?:[^\"\\\\]|\\\\.)*\"", to: result, in: fullRange, color: p.string)
        applyPattern("'(?:[^'\\\\]|\\\\.)*'", to: result, in: fullRange, color: p.string)
        // Template literals
        applyPattern("`(?:[^`\\\\]|\\\\.)*`", to: result, in: fullRange, color: p.string)

        // 6. Comments — override everything (applied last)
        applyPattern("//[^\n]*", to: result, in: fullRange, color: p.comment)
        applyPattern("#[^\n]*", to: result, in: fullRange, color: p.comment,
                     fileExtension: fileExtension,
                     enabledFor: ["py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml"])
        // Block comments
        applyMultilinePattern("/\\*[\\s\\S]*?\\*/", to: result, in: fullRange, color: p.comment)
        // HTML comments
        applyMultilinePattern("<!--[\\s\\S]*?-->", to: result, in: fullRange, color: p.comment)

        // 7. HTML/XML tags
        if ["html", "htm", "xml", "svg", "jsx", "tsx"].contains(fileExtension) {
            applyPattern("</?[a-zA-Z][a-zA-Z0-9]*", to: result, in: fullRange, color: p.keyword)
            applyPattern("/?>", to: result, in: fullRange, color: p.keyword)
        }

        return result
    }

    // MARK: - Internals

    private struct Colors {
        let keyword: NSColor
        let string: NSColor
        let comment: NSColor
        let number: NSColor
        let type: NSColor
        let attribute: NSColor
        let text: NSColor
    }

    private static func darkColors() -> Colors {
        Colors(keyword: DarkPalette.keyword, string: DarkPalette.string,
               comment: DarkPalette.comment, number: DarkPalette.number,
               type: DarkPalette.type, attribute: DarkPalette.attribute,
               text: DarkPalette.text)
    }

    private static func lightColors() -> Colors {
        Colors(keyword: LightPalette.keyword, string: LightPalette.string,
               comment: LightPalette.comment, number: LightPalette.number,
               type: LightPalette.type, attribute: LightPalette.attribute,
               text: LightPalette.text)
    }

    private static func keywordsForExtension(_ ext: String) -> [String] {
        switch ext.lowercased() {
        case "py", "pyw":
            return Array(pythonKeywords)
        case "rb":
            return Array(pythonKeywords) // Close enough for basic highlighting
        default:
            return Array(cFamilyKeywords)
        }
    }

    private static func applyPattern(
        _ pattern: String,
        to result: NSMutableAttributedString,
        in range: NSRange,
        color: NSColor,
        fileExtension: String = "",
        enabledFor extensions: [String]? = nil
    ) {
        if let extensions, !extensions.isEmpty, !extensions.contains(fileExtension.lowercased()) { return }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        regex.enumerateMatches(in: result.string, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                result.addAttribute(.foregroundColor, value: color, range: matchRange)
            }
        }
    }

    private static func applyMultilinePattern(
        _ pattern: String,
        to result: NSMutableAttributedString,
        in range: NSRange,
        color: NSColor
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
        regex.enumerateMatches(in: result.string, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                result.addAttribute(.foregroundColor, value: color, range: matchRange)
            }
        }
    }
}
