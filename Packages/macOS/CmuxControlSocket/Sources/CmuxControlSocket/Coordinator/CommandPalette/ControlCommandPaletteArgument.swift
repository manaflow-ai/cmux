/// One statically declared argument accepted by a command-palette action.
public struct ControlCommandPaletteArgument: Sendable, Equatable {
    /// Stable argument name used on the wire.
    public let name: String
    /// Wire value type, currently `string`, `path`, or `boolean`.
    public let type: String
    /// Whether automation callers must supply the argument.
    public let required: Bool
    /// Whether an explicitly supplied empty string is valid.
    public let allowsEmpty: Bool

    /// Creates an action argument description.
    public init(name: String, type: String, required: Bool, allowsEmpty: Bool) {
        self.name = name
        self.type = type
        self.required = required
        self.allowsEmpty = allowsEmpty
    }
}
