/// Summarizes one changed file and its stable viewed-state digest.
public struct ChangesFile: Sendable, Equatable {
    /// The new-side repository-relative path.
    public let path: String
    /// The old-side path for a rename or copy.
    public let oldPath: String?
    /// The kind of repository change.
    public let status: ChangesFileStatus
    /// The number of added text lines.
    public let additions: Int
    /// The number of deleted text lines.
    public let deletions: Int
    /// Whether Git or content sniffing classified the file as binary.
    public let isBinary: Bool
    /// Whether the patch exceeds the engine's line or byte threshold.
    public let isLarge: Bool
    /// A lowercase SHA-256 digest of the file's patch bytes.
    public let patchDigest: String

    /// Creates one file summary.
    /// - Parameters:
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy.
    ///   - status: The kind of repository change.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - isBinary: Whether the file is binary.
    ///   - isLarge: Whether the patch crosses a large-diff threshold.
    ///   - patchDigest: The lowercase SHA-256 patch digest.
    public init(
        path: String,
        oldPath: String?,
        status: ChangesFileStatus,
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
