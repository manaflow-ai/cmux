/// Summary metadata for one changed file.
public struct DiffFileSummary: Sendable, Codable, Equatable {
    /// The new-side repository-relative path.
    public let path: String
    /// The old-side path for renames and copies.
    public let oldPath: String?
    /// The file's working-tree status.
    public let status: DiffFileStatus
    /// The number of added lines reported by Git or counted for an untracked file.
    public let additions: Int
    /// The number of deleted lines reported by Git.
    public let deletions: Int
    /// Whether Git numstat, or in-process untracked-file inspection, identified binary content.
    public let isBinary: Bool
    /// Whether line churn exceeds 3,000 or the file patch exceeds one MiB.
    public let isLarge: Bool
    /// A lowercase SHA-256 digest of this file's patch bytes.
    public let patchDigest: String

    /// Creates changed-file summary metadata.
    /// - Parameters:
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy.
    ///   - status: The file's working-tree status.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - isBinary: Whether the file has binary content.
    ///   - isLarge: Whether the file exceeds a large-diff threshold.
    ///   - patchDigest: The lowercase SHA-256 digest of the patch bytes.
    public init(
        path: String,
        oldPath: String?,
        status: DiffFileStatus,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        isLarge: Bool,
        patchDigest: String
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isLarge = isLarge
        self.patchDigest = patchDigest
    }
}
