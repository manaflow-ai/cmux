/// One off-main filesystem snapshot for a missing Git config dependency.
struct WorkspaceGitMetadataCreationTargetSnapshot: Sendable {
    /// Whether the declared config path currently exists.
    let exists: Bool
    /// Resolved ancestor used for the safe creation watcher.
    let nearestExistingDirectory: String
    /// Lexical parent containing a symlink in the declared path, if any.
    let logicalSymlinkParent: String?
    /// Stable symlink destinations used to detect retargeting.
    let logicalSymlinkSignature: String?
}
