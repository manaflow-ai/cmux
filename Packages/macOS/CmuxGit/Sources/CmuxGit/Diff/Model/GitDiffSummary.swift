/// A changed-file summary produced from git diff status output.
public struct GitDiffSummary: Sendable, Codable, Equatable, Identifiable {
    /// Stable row identity.
    public var id: String { path }
    /// New/current repository-relative path.
    public let path: String
    /// Old repository-relative path for renamed files.
    public let oldPath: String?
    /// File status.
    public let status: GitDiffStatus
    /// Added-line count, when git reports one.
    public let additions: Int?
    /// Deleted-line count, when git reports one.
    public let deletions: Int?
    /// Opaque identity of the repository state that produced this row.
    public let snapshotToken: String

    /// Creates a changed-file summary.
    ///
    /// - Parameters:
    ///   - path: New/current repository-relative path.
    ///   - oldPath: Old repository-relative path for renamed files.
    ///   - status: File status.
    ///   - additions: Added-line count, when git reports one.
    ///   - deletions: Deleted-line count, when git reports one.
    ///   - snapshotToken: Opaque identity of the repository state for this row.
    public init(
        path: String,
        oldPath: String?,
        status: GitDiffStatus,
        additions: Int?,
        deletions: Int?,
        snapshotToken: String = ""
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.snapshotToken = snapshotToken
    }
}
