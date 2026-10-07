/// Bounds of the git family on this Mac (c13-viewers.md section 2). Every
/// reply must fit one `rpc` frame, below `hello.ok.max_frame`.
public struct MobileGitConfiguration: Hashable, Sendable {
    /// Per-file patch cap passed to the session host (and its default).
    public var maxPatchBytes: Int
    /// Files per reply cap.
    public var maxFiles: Int
    public var defaultMaxFiles: Int
    /// Encoded `git.diff` results above this drop patches, then files.
    public var maxReplyBytes: Int
    /// `paths` entries per request.
    public var maxPaths: Int

    public init(maxPatchBytes: Int = 128 * 1024, maxFiles: Int = 1000, defaultMaxFiles: Int = 500,
                maxReplyBytes: Int = 192 * 1024, maxPaths: Int = 256) {
        self.maxPatchBytes = maxPatchBytes
        self.maxFiles = maxFiles
        self.defaultMaxFiles = defaultMaxFiles
        self.maxReplyBytes = maxReplyBytes
        self.maxPaths = maxPaths
    }
}
