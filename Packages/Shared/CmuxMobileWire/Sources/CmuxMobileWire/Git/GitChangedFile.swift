/// One changed file of a `git.diff` result.
public struct GitChangedFile: Hashable, Sendable, Codable {
    /// Relative to the repository root.
    public var path: String
    /// The path before a rename.
    public var previousPath: String?
    public var status: GitChangeStatus
    public var additions: Int
    public var deletions: Int
    /// True for a binary file, which has no patch.
    public var binary: Bool?
    /// The unified diff from its first `@@` line, only with `include_patch`.
    public var patch: String?
    /// True when the patch stopped at a byte budget.
    public var patchTruncated: Bool?

    public init(path: String, previousPath: String? = nil, status: GitChangeStatus, additions: Int = 0, deletions: Int = 0,
                binary: Bool? = nil, patch: String? = nil, patchTruncated: Bool? = nil) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
        self.patch = patch
        self.patchTruncated = patchTruncated
    }

    public var isBinary: Bool { binary == true }
    public var isPatchTruncated: Bool { patchTruncated == true }

    enum CodingKeys: String, CodingKey {
        case path, status, additions, deletions, binary, patch
        case previousPath = "previous_path"
        case patchTruncated = "patch_truncated"
    }
}
