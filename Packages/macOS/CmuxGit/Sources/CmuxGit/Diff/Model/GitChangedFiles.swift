/// Changed-file listing for mobile diff review, with an explicit truncation
/// marker so callers can bound memory and tell the client the list is partial.
public struct GitChangedFiles: Sendable, Equatable {
    /// Changed-file summaries in path order.
    public let files: [GitDiffSummary]
    /// Whether any of the underlying git listings hit the caller's output
    /// bound and were cut off, making `files` a partial view of the repo.
    public let truncated: Bool

    /// Creates a changed-file listing.
    ///
    /// - Parameters:
    ///   - files: Changed-file summaries in path order.
    ///   - truncated: Whether any underlying git listing was cut off.
    public init(files: [GitDiffSummary], truncated: Bool) {
        self.files = files
        self.truncated = truncated
    }
}
