/// Swift spellings of schema names for TypeEmitter: wire names are
/// kebab-, snake- or dot-separated lower case; Swift members are lowerCamelCase
/// and types UpperCamelCase, with `id`/`ids` written `ID`/`IDs` (the app's
/// convention, `SurfaceID`, `terminalID`).
struct SwiftNames {
    /// Words Swift reserves in a declaration; a member with one of these names is
    /// written in backticks.
    static let keywords: Set<String> = [
        "Any", "Protocol", "Self", "Type", "as", "associatedtype", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false",
        "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
        "nil", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "var", "where", "while",
    ]

    let wire: String

    init(_ wire: String) {
        self.wire = wire
    }

    private var words: [Substring] {
        wire.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " })
    }

    private static func capitalized(_ word: Substring) -> String {
        switch word {
        case "id": "ID"
        case "ids": "IDs"
        default: word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    /// `active_pane` -> `ActivePane`, `utf-8` -> `Utf8`, `terminal_id` -> `TerminalID`.
    var type: String {
        let name = words.map(Self.capitalized).joined()
        return name.first?.isNumber == true ? "_" + name : name
    }

    /// `active_pane` -> `activePane`, `terminal_id` -> `terminalID`, `id` -> `id`,
    /// `2d` -> `_2d`; a name backticks cannot make usable gets `Value` (`self` -> `selfValue`).
    var member: String {
        guard let first = words.first else { return "_" }
        var name = String(first) + words.dropFirst().map(Self.capitalized).joined()
        if name.first?.isNumber == true { name = "_" + name }
        return Self.unusable.contains(name) ? name + "Value" : name
    }

    /// ``member`` as written in a declaration, a label or after a dot.
    var escapedMember: String {
        Self.escaped(member)
    }

    /// Names that stay special even in backticks as a member or case.
    static let unusable: Set<String> = ["self", "Self", "super", "init", "deinit", "subscript", "Type", "Protocol", "rawValue"]

    static func escaped(_ name: String) -> String {
        keywords.contains(name) ? "`\(name)`" : name
    }

    /// An enum case for a named variant type: `LivePane` -> `livePane`, `CLIJob` -> `cLIJob`.
    static func caseName(ofType type: String) -> String {
        escaped(type.prefix(1).lowercased() + type.dropFirst())
    }

    /// A Swift string literal of `text`: escapes quotes, backslashes and every
    /// scalar outside printable ASCII, so schema text can never end the literal
    /// or start an interpolation.
    static func literal(_ text: String) -> String {
        TableEmitter.literal(text)
    }

    /// Schema prose as `///` lines: one line, no comment terminators to break out of.
    static func doc(_ text: String?, indent: String) -> String {
        guard let text, !text.isEmpty else { return "" }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(indent)/// \(line)\n"
    }
}
