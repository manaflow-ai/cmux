/// A file-level changed-file summary.
public struct DiffFileSummary: Sendable, Codable, Equatable, Identifiable {
    /// Stable row identity.
    public var id: String { oldPath.map { "\($0)->\(path)" } ?? path }
    /// New/current repository-relative path.
    public let path: String
    /// Old repository-relative path for renames.
    public let oldPath: String?
    /// File status.
    public let status: DiffFileStatus
    /// Added-line count, when known.
    public let additions: Int?
    /// Deleted-line count, when known.
    public let deletions: Int?

    /// Creates a file-level changed-file summary.
    ///
    /// - Parameters:
    ///   - path: New/current repository-relative path.
    ///   - oldPath: Old repository-relative path for renames.
    ///   - status: File status.
    ///   - additions: Added-line count, when known.
    ///   - deletions: Deleted-line count, when known.
    public init(path: String, oldPath: String?, status: DiffFileStatus, additions: Int?, deletions: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}
