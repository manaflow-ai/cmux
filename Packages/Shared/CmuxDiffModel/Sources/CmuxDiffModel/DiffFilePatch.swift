/// Raw unified diff text for one selected file.
public struct DiffFilePatch: Sendable, Equatable {
    /// Repository-relative file path.
    public let path: String
    /// Raw unified diff text.
    public let unifiedDiff: String
    /// Whether the producer capped the diff text.
    public let isTruncated: Bool

    /// Creates a one-file patch.
    public init(path: String, unifiedDiff: String, isTruncated: Bool) {
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.isTruncated = isTruncated
    }
}
