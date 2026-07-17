/// Summary metadata for one changed file.
public struct MobileDiffFileSummary: Codable, Sendable, Equatable {
    /// The new-side repository-relative path.
    public let path: String
    /// The old-side path for a rename or copy.
    public let oldPath: String?
    /// The file's change status.
    public let status: MobileDiffFileStatus
    /// The number of added lines.
    public let additions: Int
    /// The number of deleted lines.
    public let deletions: Int
    /// Whether the file contains binary content.
    public let isBinary: Bool
    /// Whether the file exceeds the large-diff threshold.
    public let isLarge: Bool
    /// The lowercase SHA-256 digest of the file patch.
    public let patchDigest: String

    /// Creates changed-file summary metadata.
    /// - Parameters:
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy.
    ///   - status: The file's change status.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - isBinary: Whether the file contains binary content.
    ///   - isLarge: Whether the file exceeds the large-diff threshold.
    ///   - patchDigest: The lowercase SHA-256 digest of the file patch.
    public init(
        path: String,
        oldPath: String? = nil,
        status: MobileDiffFileStatus,
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
