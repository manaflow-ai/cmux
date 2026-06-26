/// A persisted git branch indicator inside a session snapshot.
///
/// A pure leaf value carrying the current `branch` name and whether the working
/// tree `isDirty`. The on-disk wire format is owned by the app's session panel
/// snapshots; encoding stays byte-identical to the legacy app-target
/// definition.
public struct SessionGitBranchSnapshot: Codable, Sendable {
    /// The current branch name.
    public var branch: String
    /// Whether the working tree has uncommitted changes.
    public var isDirty: Bool

    /// Creates a persisted git branch snapshot.
    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}
