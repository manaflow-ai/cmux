/// A stable, string-backed mobile pane identifier.
public struct MobilePanePreviewID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    /// The underlying pane identifier string.
    public var rawValue: String

    /// Creates an identifier from its raw string value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a string literal.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
