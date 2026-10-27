/// A generated typed resource id (`V2TerminalID`): the public id string of one resource scope.
/// Ids encode as their string.
public protocol ResourceIdentifier: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    /// The catalog's resource scope (`terminal`).
    static var scope: String { get }
}

/// A selector param (`machine`, `session`, `terminal`, ...): an id, a name or `current`
/// (resource-api-v2.md, selectors). Encodes as its string.
public struct ResourceSelector: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The connected owner or session; the default of the `machine` and `session` selectors.
    public static let current = ResourceSelector(rawValue: "current")

    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// Selects the resource with id `id`.
    public init(_ id: some ResourceIdentifier) {
        rawValue = id.rawValue
    }
}
