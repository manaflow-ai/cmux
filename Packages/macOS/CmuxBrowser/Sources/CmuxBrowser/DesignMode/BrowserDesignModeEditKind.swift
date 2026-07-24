/// The kind of mutation recorded by design mode.
public enum BrowserDesignModeEditKind: String, Codable, Equatable, Sendable {
    /// A CSS property override.
    case style
    /// A leaf element's text or form value.
    case text
}
