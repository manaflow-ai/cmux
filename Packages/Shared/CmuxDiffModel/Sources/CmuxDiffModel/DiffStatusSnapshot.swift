/// One bounded changed-file snapshot for a workspace repository.
public struct DiffStatusSnapshot: Sendable, Equatable {
    /// Repository root that identifies later file requests.
    public let repoRoot: String
    /// Changed files in display order.
    public let files: [DiffFileSummary]
    /// Whether the producer capped the changed-file list.
    public let isTruncated: Bool

    /// Creates a changed-file snapshot.
    public init(repoRoot: String, files: [DiffFileSummary], isTruncated: Bool) {
        self.repoRoot = repoRoot
        self.files = files
        self.isTruncated = isTruncated
    }
}
