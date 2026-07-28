/// The value representation accepted by a cmux action argument.
public enum CmuxActionArgumentValueType: String, Sendable {
    /// An opaque string value.
    case string
    /// A filesystem path resolved relative to the automation caller.
    case path
    /// A boolean encoded as a supported wire string.
    case boolean
}
