#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Syntax colours for fenced code (shared/MARKDOWN.md). One linear scan per block
/// (comments, strings, numbers, keywords, type names; diff lines), during layout,
/// so it runs where layout runs: off main except for the tail of a stream. Tokens
/// are an attribute (`.mdToken`); MarkdownDraw maps them to colours per bubble.
enum MDToken: UInt8 { case plain, keyword, string, comment, number, type, added, removed, meta }

enum MarkdownHighlight {
    struct Lang {
        var keywords: Set<String>
        var line: [String]          // line comment starts
        var block: (String, String)?
        var quotes: Set<UInt16>     // " ' `
        var types = true            // Capitalized identifiers are types
    }

    private static let cLike: Set<String> = ["if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "true", "false", "null", "nil", "new", "class", "struct", "enum", "const", "static", "void", "import", "export", "public", "private", "protected", "try", "catch", "throw", "throws", "finally", "in", "is", "as", "this", "self", "super"]
    static let langs: [String: Lang] = {
        let swift: Set<String> = cLike.union(["func", "let", "var", "guard", "defer", "extension", "protocol", "init", "deinit", "where", "inout", "some", "any", "async", "await", "actor", "final", "override", "fileprivate", "internal", "open", "typealias", "associatedtype", "mutating", "weak", "unowned", "lazy", "repeat", "fallthrough", "Self", "rethrows", "subscript", "operator"])
        let js: Set<String> = cLike.union(["function", "let", "var", "of", "typeof", "instanceof", "undefined", "async", "await", "yield", "from", "extends", "implements", "interface", "type", "readonly", "delete", "declare", "namespace", "keyof", "satisfies"])
        let py: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "True", "False", "None", "and", "or", "not", "in", "is", "global", "nonlocal", "async", "await", "assert", "del", "match", "case", "self"]
        let go: Set<String> = cLike.union(["func", "package", "var", "type", "interface", "map", "chan", "go", "select", "range", "defer", "fallthrough", "goto", "iota"])
        let rust: Set<String> = cLike.union(["fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "crate", "match", "loop", "where", "move", "ref", "dyn", "unsafe", "async", "await", "Self", "type", "None", "Some", "Ok", "Err"])
        let sh: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "set", "unset", "echo", "cd", "exit", "source", "true", "false", "readonly", "shift", "until"]
        let sql: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "primary", "key", "references", "default", "distinct", "union", "all", "case", "when", "then", "else", "end", "with", "returning", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "JOIN", "LEFT", "INNER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "PRIMARY", "KEY", "DEFAULT", "DISTINCT", "UNION", "CASE", "WHEN", "THEN", "ELSE", "END", "WITH", "RETURNING"]
        let q2: Set<UInt16> = [34, 39], q3: Set<UInt16> = [34, 39, 96]
        var m: [String: Lang] = [:]
        m["swift"] = Lang(keywords: swift, line: ["//"], block: ("/*", "*/"), quotes: [34])
        for k in ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"] { m[k] = Lang(keywords: js, line: ["//"], block: ("/*", "*/"), quotes: q3) }
        for k in ["py", "python", "python3"] { m[k] = Lang(keywords: py, line: ["#"], block: nil, quotes: q2) }
        m["go"] = Lang(keywords: go, line: ["//"], block: ("/*", "*/"), quotes: q3)
        for k in ["rs", "rust"] { m[k] = Lang(keywords: rust, line: ["//"], block: ("/*", "*/"), quotes: [34]) }
        for k in ["sh", "bash", "zsh", "shell", "console", "fish"] { m[k] = Lang(keywords: sh, line: ["#"], block: nil, quotes: q2, types: false) }
        for k in ["c", "h", "cpp", "c++", "cc", "hpp", "objc", "m", "mm", "java", "kotlin", "kt", "cs", "csharp", "zig", "dart", "scala"] {
            m[k] = Lang(keywords: cLike.union(["int", "long", "char", "float", "double", "bool", "unsigned", "signed", "auto", "fun", "val", "var", "fn", "pub", "using", "namespace", "template", "typename", "sizeof", "extern", "inline", "virtual", "goto", "typedef", "union", "package", "extends", "implements", "interface", "abstract", "final", "override", "when", "object", "data"]), line: ["//"], block: ("/*", "*/"), quotes: q2)
        }
        for k in ["sql", "psql", "postgres", "sqlite"] { m[k] = Lang(keywords: sql, line: ["--"], block: ("/*", "*/"), quotes: q2, types: false) }
        for k in ["json", "jsonc", "json5"] { m[k] = Lang(keywords: ["true", "false", "null"], line: ["//"], block: ("/*", "*/"), quotes: [34], types: false) }
        for k in ["yaml", "yml", "toml", "ini", "conf", "dockerfile", "make", "makefile", "ruby", "rb", "perl", "r", "nix"] {
            m[k] = Lang(keywords: ["true", "false", "null", "yes", "no", "on", "off", "def", "end", "if", "else", "elsif", "unless", "do", "class", "module", "require", "return", "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "ENTRYPOINT", "ARG", "let", "in", "with", "inherit", "rec"], line: ["#"], block: nil, quotes: q2, types: false)
        }
        for k in ["css", "scss", "less"] { m[k] = Lang(keywords: ["important", "media", "import", "keyframes", "from", "to"], line: k == "css" ? [] : ["//"], block: ("/*", "*/"), quotes: q2, types: false) }
        for k in ["lua"] { m[k] = Lang(keywords: ["local", "function", "end", "if", "then", "else", "elseif", "for", "while", "do", "return", "nil", "true", "false", "and", "or", "not", "repeat", "until", "in", "break"], line: ["--"], block: nil, quotes: q2, types: false) }
        return m
    }()

    /// Attributed code: mono font, tokens. `lang` may be empty (no colours) or "diff".
    static func attributed(_ code: String, lang: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: code, attributes: [.font: Markdown.codeFont, .mdRole: MDRole.code.rawValue, .paragraphStyle: tabStyle])
        let l = lang.lowercased()
        if l == "diff" || l == "patch" { diff(a); return a }
        guard let spec = langs[l] else { return a }
        scan(a, spec)
        return a
    }

    /// Tabs every 4 columns of the mono font (code keeps its tab characters).
    static let tabStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        let w = ("    " as NSString).size(withAttributes: [.font: Markdown.codeFont]).width
        p.tabStops = []
        p.defaultTabInterval = max(8, w)
        return p
    }()

    private static func set(_ a: NSMutableAttributedString, _ r: NSRange, _ t: MDToken) {
        guard r.length > 0 else { return }
        a.addAttribute(.mdToken, value: t.rawValue, range: r)
    }

    private static func diff(_ a: NSMutableAttributedString) {
        let ns = a.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            guard r.length > 0 else { return }
            let c = ns.character(at: r.location)
            let isHeader = ns.substring(with: r).hasPrefix("+++") || ns.substring(with: r).hasPrefix("---")
            if c == 64 || isHeader { set(a, r, .meta) }           // @@ hunk headers, file headers
            else if c == 43 { set(a, r, .added) }                 // +
            else if c == 45 { set(a, r, .removed) }               // -
        }
    }

    private static func scan(_ a: NSMutableAttributedString, _ spec: Lang) {
        let ns = a.string as NSString
        let n = ns.length
        // Very long blocks: colours for the first 64k units only (bounded layout time).
        let limit = min(n, 65_536)
        var buf = [UInt16](repeating: 0, count: limit)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: limit))
        let lineStarts = spec.line.map { Array($0.utf16) }
        let blockOpen = spec.block.map { Array($0.0.utf16) }, blockClose = spec.block.map { Array($0.1.utf16) }
        func starts(_ p: [UInt16], at i: Int) -> Bool {
            guard i + p.count <= limit else { return false }
            for k in p.indices where buf[i + k] != p[k] { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 0x80 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        var i = 0
        while i < limit {
            let c = buf[i]
            if let bo = blockOpen, let bc = blockClose, starts(bo, at: i) {
                var j = i + bo.count
                while j < limit, !starts(bc, at: j) { j += 1 }
                j = min(limit, j + bc.count)
                set(a, NSRange(location: i, length: j - i), .comment); i = j; continue
            }
            if lineStarts.contains(where: { starts($0, at: i) }), !(c == 35 && i > 0 && isIdent(buf[i - 1])) {
                var j = i
                while j < limit, buf[j] != 10 { j += 1 }
                set(a, NSRange(location: i, length: j - i), .comment); i = j; continue
            }
            if spec.quotes.contains(c) {
                // Python triple quotes; else to the closing quote on the line (backticks span lines).
                let triple = i + 2 < limit && buf[i + 1] == c && buf[i + 2] == c
                var j = i + (triple ? 3 : 1)
                while j < limit {
                    if buf[j] == 92 { j += 2; continue }
                    if triple { if j + 2 < limit, buf[j] == c, buf[j + 1] == c, buf[j + 2] == c { j += 3; break } }
                    else if buf[j] == c { j += 1; break }
                    else if buf[j] == 10, c != 96 { break }
                    j += 1
                }
                j = min(j, limit)
                set(a, NSRange(location: i, length: j - i), .string); i = j; continue
            }
            if c >= 48 && c <= 57, i == 0 || !isIdent(buf[i - 1]) {
                var j = i + 1
                while j < limit, isIdent(buf[j]) || buf[j] == 46 && j + 1 < limit && buf[j + 1] >= 48 && buf[j + 1] <= 57 { j += 1 }
                set(a, NSRange(location: i, length: j - i), .number); i = j; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < limit, isIdent(buf[j]) { j += 1 }
                let r = NSRange(location: i, length: j - i)
                let w = ns.substring(with: r)
                if spec.keywords.contains(w) { set(a, r, .keyword) }
                else if spec.types, c >= 65, c <= 90, j - i > 1 { set(a, r, .type) }
                i = j; continue
            }
            i += 1
        }
    }
}
