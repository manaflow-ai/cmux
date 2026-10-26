/// Swift spellings of catalog names for ResourceEmitter. Words, initialisms (`terminal_id` is
/// `terminalID`, `local.io` is `LocalIO`) and keywords are SwiftNaming's, so the v1 and v2
/// bindings spell a wire name the same way; this adds only the v2 rules: the `V2` prefix, the
/// members and nested types the generated declarations already use, and refusing a name with no
/// identifier instead of inventing one.
///
/// Every generated top-level name starts with `V2`, so CmuxNextIPC's v2 types never shadow a
/// CmuxNextDaemon type a file imports beside them.
struct ResourceSwiftName {
    /// The name as it is written in Swift (backquoted when it is a keyword).
    let spelling: String

    static let prefix = "V2"

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

    /// A member (property, coding key, case or static) for wire name `name` at catalog `path`.
    static func member(_ name: String, path: String) throws(ResourceEmitterError) -> ResourceSwiftName {
        try checkIdentifier(name, path: path)
        var identifier = SwiftNaming.propertyName(name)
        if takenMembers.contains(identifier) { identifier += "Value" }
        return ResourceSwiftName(spelling: SwiftNaming.identifier(identifier))
    }

    /// An UpperCamel name for wire name `name` (`terminal.input.write` is `TerminalInputWrite`),
    /// without the prefix: the caller adds `V2` and a suffix, or nests it.
    static func upperCamel(_ name: String, path: String) throws(ResourceEmitterError) -> String {
        try checkIdentifier(name, path: path)
        return SwiftNaming.typeName(name)
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

    /// The first of SwiftNaming's words must start with a letter, or there is no Swift identifier
    /// to make (SwiftNaming would prefix `_`).
    private static func checkIdentifier(_ name: String, path: String) throws(ResourceEmitterError) {
        guard let first = SwiftNaming.words(name).first?.unicodeScalars.first, ("a"..."z").contains(first) else {
            throw .unsupported(path: path, reason: "`\(name)` has no Swift name")
        }
    }
}
