/// One argument of a ``RenderModifier``: an optional label and a resolved
/// string value (evaluated where possible, else the source token like
/// `.infinity` or `.leading`).
public struct ModifierArg: Codable, Sendable, Equatable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}
