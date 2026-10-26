/// Swift spellings of catalog names for ResourceEmitter: `V2` + the catalog's UpperCamel type
/// names, UpperCamel request and details names from dotted wire names, and lowerCamel members
/// with `id`, `ids`, `url` and `urls` as `ID`, `IDs`, `URL` and `URLs` after the first word.
///
/// Every generated top-level name starts with `V2`, so CmuxNextIPC's v2 types never shadow a
/// CmuxNextDaemon type a file imports beside them.
struct ResourceSwiftName {
    /// The name as it is written in Swift (backquoted when it is a keyword).
    let spelling: String

    static let prefix = "V2"

    /// Swift keywords a member may be named with backquotes.
    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
        "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
        "where", "while", "as", "await", "false", "is", "nil", "super", "throws", "true", "try", "Any",
    ]

    /// Members that even backquoted mean something else (`x.self`, `.init`) or that the generated
    /// declarations already use; a field or value with one of these names gets `Value` appended.
    private static let takenMembers: Set<String> = [
        "self", "init", "rawValue", "stringValue", "intValue", "resourceOperation",
    ]

    /// Nested type names that would shadow a type the generated code spells inside the parent
    /// (or that Swift reserves); an inline type with one of these names gets `Value` appended.
    private static let takenTypes: Set<String> = [
        "Self", "Type", "Protocol", "CodingKeys", "Result", "StreamItem", "StreamEnd", "T",
        "String", "Bool", "UInt16", "UInt32", "UInt64", "Int32", "Double", "Optional", "Decoder", "Encoder",
        "Error", "Sendable", "Equatable", "Hashable", "Codable", "CodingKey", "RawRepresentable", "Any", "Swift",
        "ResourceJSON", "ResourceSelector", "ResourceCodingKey",
    ]

    private static let acronyms = ["id": "ID", "ids": "IDs", "url": "URL", "urls": "URLs"]

    /// A member (property, coding key, case or static) for wire name `name` at catalog `path`.
    static func member(_ name: String, path: String) throws(ResourceEmitterError) -> ResourceSwiftName {
        let parts = try words(name, path: path)
        var identifier = lowercasedFirst(parts[0])
        for word in parts.dropFirst() { identifier += acronyms[word] ?? uppercasedFirst(word) }
        if takenMembers.contains(identifier) { identifier += "Value" }
        return ResourceSwiftName(spelling: keywords.contains(identifier) ? "`\(identifier)`" : identifier)
    }

    /// An UpperCamel name for wire name `name` (`terminal.input.write` is `TerminalInputWrite`),
    /// without the prefix: the caller adds `V2` and a suffix, or nests it.
    static func upperCamel(_ name: String, path: String) throws(ResourceEmitterError) -> String {
        try words(name, path: path).map { acronyms[$0] ?? uppercasedFirst($0) }.joined()
    }

    /// A nested type for the inline shape of field (or role) `name`.
    static func nestedType(_ name: String, path: String) throws(ResourceEmitterError) -> String {
        let identifier = try upperCamel(name, path: path)
        return takenTypes.contains(identifier) ? identifier + "Value" : identifier
    }

    /// The Swift name of catalog type or generic `name` (already UpperCamel in the catalog).
    static func type(_ name: String) -> String {
        prefix + name
    }

    /// The typed id of resource scope `scope` (`terminal` is `V2TerminalID`).
    static func identifier(scope: String, path: String) throws(ResourceEmitterError) -> String {
        try prefix + upperCamel(scope, path: path) + "ID"
    }

    /// Splits on every character that is not an ASCII letter or digit; the first word must start
    /// with a letter, or there is no Swift identifier to make.
    private static func words(_ name: String, path: String) throws(ResourceEmitterError) -> [String] {
        let parts = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        guard let first = parts.first?.first, first.isLetter else {
            throw .unsupported(path: path, reason: "`\(name)` has no Swift name")
        }
        return parts
    }

    private static func lowercasedFirst(_ word: String) -> String {
        word.prefix(1).lowercased() + word.dropFirst()
    }

    private static func uppercasedFirst(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }
}
