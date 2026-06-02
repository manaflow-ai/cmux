/// A single name/value pair appended to a provider's list request query string.
///
/// Stored as an ordered array (rather than a dictionary) so a provider can repeat a
/// parameter, e.g. Bitbucket needs `state=OPEN&state=MERGED&state=DECLINED` to list
/// every pull request state in one call. Values may contain the template tokens
/// described on ``GitHostingProviderSpec`` (`{owner}`, `{branch}`, …).
public struct GitHostingQueryItem: Sendable, Codable, Equatable {
    /// The query parameter name.
    public var name: String

    /// The query parameter value (URL-encoded automatically when the request is built).
    public var value: String

    /// Creates a query item.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}
