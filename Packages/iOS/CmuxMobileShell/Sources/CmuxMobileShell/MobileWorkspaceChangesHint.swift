/// A one-time discoverability hint for a workspace with reviewable changes.
public struct MobileWorkspaceChangesHint: Equatable, Sendable {
    /// The Mac-local workspace identifier whose changes can be reviewed.
    public let workspaceID: String

    /// Creates an eligible hint when changes are supported, present, and unseen.
    ///
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - workspaceChangesCapable: Whether the connected Mac supports changes.
    ///   - chip: The latest immutable summary for the workspace.
    ///   - isDismissed: Whether this workspace's hint has already been seen.
    public init?(
        workspaceID: String,
        workspaceChangesCapable: Bool,
        chip: MobileWorkspaceChangesChip?,
        isDismissed: Bool
    ) {
        guard workspaceChangesCapable,
              !workspaceID.isEmpty,
              chip?.filesChanged ?? 0 > 0,
              !isDismissed else { return nil }
        self.workspaceID = workspaceID
    }
}
