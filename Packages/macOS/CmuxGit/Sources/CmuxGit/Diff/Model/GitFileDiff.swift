/// Raw unified diff text for one changed file.
public struct GitFileDiff: Sendable, Codable, Equatable {
    /// Repository-relative path requested by the client.
    public let path: String
    /// Raw unified diff text.
    public let unifiedDiff: String

    /// Creates a one-file diff response.
    ///
    /// - Parameters:
    ///   - path: Repository-relative path requested by the client.
    ///   - unifiedDiff: Raw unified diff text.
    public init(path: String, unifiedDiff: String) {
        self.path = path
        self.unifiedDiff = unifiedDiff
    }
}
