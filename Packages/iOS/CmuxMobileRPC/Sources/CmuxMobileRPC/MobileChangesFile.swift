/// Summarizes one changed repository file.
public struct MobileChangesFile: Codable, Sendable, Equatable {
    /// The new-side repository-relative path.
    public let path: String
    /// The old-side path for a rename or copy, when present.
    public let oldPath: String?
    /// The file's change classification.
    public let status: MobileChangesFileStatus
    /// The number of added lines.
    public let additions: Int
    /// The number of deleted lines.
    public let deletions: Int
    /// Whether the file is binary.
    public let isBinary: Bool
    /// Whether the host withheld the initial patch because it exceeds the large-file threshold.
    public let isLarge: Bool
    /// The stable digest of the current patch bytes.
    public let patchDigest: String

    /// Creates a changed-file summary.
    /// - Parameters:
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy, when present.
    ///   - status: The file's change classification.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - isBinary: Whether the file is binary.
    ///   - isLarge: Whether the patch exceeds the host's large-file threshold.
    ///   - patchDigest: The stable digest of the current patch bytes.
    public init(
        path: String,
        oldPath: String?,
        status: MobileChangesFileStatus,
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

    private enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case additions
        case deletions
        case isBinary = "is_binary"
        case isLarge = "is_large"
        case patchDigest = "patch_digest"
    }
}
