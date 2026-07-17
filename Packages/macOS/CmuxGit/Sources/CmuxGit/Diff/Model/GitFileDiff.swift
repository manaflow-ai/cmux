/// Raw unified diff text for one changed file.
public struct GitFileDiff: Sendable, Codable, Equatable {
    /// Repository-relative path requested by the client.
    public let path: String
    /// Raw unified diff text.
    public let unifiedDiff: String
    /// Whether output hit the caller's byte cap.
    public let truncated: Bool

    /// Creates a one-file diff response.
    ///
    /// - Parameters:
    ///   - path: Repository-relative path requested by the client.
    ///   - unifiedDiff: Raw unified diff text.
    public init(path: String, unifiedDiff: String, truncated: Bool = false) {
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.truncated = truncated
    }
}
