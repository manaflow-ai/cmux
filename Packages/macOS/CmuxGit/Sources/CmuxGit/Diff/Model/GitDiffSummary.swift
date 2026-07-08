/// A changed-file summary produced from git diff status output.
public struct GitDiffSummary: Sendable, Codable, Equatable, Identifiable {
    /// Stable row identity.
    public var id: String { oldPath.map { "\($0)->\(path)" } ?? path }
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

    /// Creates a changed-file summary.
    ///
    /// - Parameters:
    ///   - path: New/current repository-relative path.
    ///   - oldPath: Old repository-relative path for renamed files.
    ///   - status: File status.
    ///   - additions: Added-line count, when git reports one.
    ///   - deletions: Deleted-line count, when git reports one.
    public init(path: String, oldPath: String?, status: GitDiffStatus, additions: Int?, deletions: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}
