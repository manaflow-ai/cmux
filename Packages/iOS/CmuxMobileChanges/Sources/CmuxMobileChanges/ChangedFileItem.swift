/// Immutable change metadata for one repository-relative path.
public struct ChangedFileItem: Sendable, Equatable, Identifiable {
    /// Current repository-relative path and stable list identity.
    public let path: String
    /// Previous path for a rename.
    public let oldPath: String?
    /// File change category.
    public let kind: FileChangeKind
    /// Number of added lines, or zero for binary content.
    public let additions: Int
    /// Number of deleted lines, or zero for binary content.
    public let deletions: Int
    /// Whether Git identified the file as binary.
    public let isBinary: Bool
    /// Whether the additions count is partial because the host reached a read cap.
    public let isApproximate: Bool?
    /// Raw file size when the mounting layer has already loaded it.
    public let byteSize: Int64?

    /// Stable list identity derived from ``path``.
    public var id: String { path }

    /// Creates a changed-file value.
    /// - Parameters:
    ///   - path: Current repository-relative path.
    ///   - oldPath: Previous path for a rename.
    ///   - kind: File change category.
    ///   - additions: Number of added lines.
    ///   - deletions: Number of deleted lines.
    ///   - isBinary: Whether the content is binary.
    ///   - isApproximate: Whether the additions count is partial.
    ///   - byteSize: Raw file size when known.
    public init(
        path: String,
        oldPath: String? = nil,
        kind: FileChangeKind,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        isApproximate: Bool? = nil,
        byteSize: Int64? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isApproximate = isApproximate
        self.byteSize = byteSize
    }
}

/// Compatibility name for a changed-file snapshot used by the locked feature spec.
public typealias ChangedFileSummary = ChangedFileItem
