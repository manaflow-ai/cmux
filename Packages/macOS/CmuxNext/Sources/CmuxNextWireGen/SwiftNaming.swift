/// Swift names for wire names, split into words the way
/// cmux-tui/bindings/codegen/naming.py `words` splits them (so every language's
/// binding agrees on the words), with Swift's initialisms (`terminal_id` ->
/// `terminalID`).
struct SwiftNaming {
    static let initialisms = [
        "api": "API", "cli": "CLI", "id": "ID", "ids": "IDs", "io": "IO", "url": "URL", "urls": "URLs",
    ]
    /// Words that need backticks as identifiers.
    static let keywords: Set<String> = [
        "Any", "Self", "as", "associatedtype", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "operator", "precedencegroup",
        "private", "protocol", "public", "repeat", "rethrows", "return", "self", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]

    /// Lowercase words: runs of ASCII letters and digits, also split before an
    /// uppercase letter that follows a lowercase letter or digit, and before the
    /// last capital of a run followed by a lowercase letter (`HTTPServer` -> http, server).
    static func words(_ value: String) -> [String] {
        let scalars = Array(value.unicodeScalars)
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            guard scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) else {
                if !current.isEmpty { words.append(String(current)) }
                current = String.UnicodeScalarView()
                continue
            }
            if let previous = current.last, isUpper(scalar) {
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if !isUpper(previous) || next.map(isLower) == true {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            }
            current.append(scalar)
        }
        if !current.isEmpty { words.append(String(current)) }
        return words.map { $0.lowercased() }
    }

    /// `new-pane-right` -> `NewPaneRight`, `agent-cli-update-job` -> `AgentCLIUpdateJob`.
    static func typeName(_ wire: String) -> String {
        safe(words(wire).map(capitalized).joined())
    }

    /// `expect_foreground` -> `expectForeground`, `terminal_id` -> `terminalID`.
    static func propertyName(_ wire: String) -> String {
        let parts = words(wire)
        guard let first = parts.first else { return "_" }
        return safe(first + parts.dropFirst().map(capitalized).joined())
    }

    /// `name`, in backticks when it is a keyword.
    static func identifier(_ name: String) -> String {
        keywords.contains(name) ? "`\(name)`" : name
    }

    static func hex(_ value: UInt8) -> String {
        MethodTableSchemaReader.hex(UInt16(value), width: 2)
    }

    private static func capitalized(_ word: String) -> String {
        initialisms[word] ?? word.prefix(1).uppercased() + word.dropFirst()
    }

    private static func safe(_ name: String) -> String {
        guard let first = name.unicodeScalars.first else { return "_" }
        return ("0"..."9").contains(first) ? "_" + name : name
    }

    private static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar)
    }

    private static func isLower(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar)
    }
}
