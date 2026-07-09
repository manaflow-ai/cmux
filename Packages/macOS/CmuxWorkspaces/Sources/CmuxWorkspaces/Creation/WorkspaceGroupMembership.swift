public import Foundation

/// The group membership of a window's currently-selected workspace, read by the
/// new-workspace routing to resolve an in-group creation target.
///
/// A `Sendable` projection of the legacy `workspaceGroupNewWorkspaceTarget(in:)`
/// group lookup: the selected workspace (the placement reference), its group,
/// and the group anchor workspace's current directory (which keys the per-window
/// workspace-group config). ``WorkspaceCreationActionCoordinator`` reads this
/// from the host, resolves the placement, and builds the
/// ``WorkspaceGroupNewWorkspaceTarget``.
public struct WorkspaceGroupMembership: Sendable, Equatable {
    /// The currently-selected workspace, used as the placement reference.
    public let selectedWorkspaceId: UUID
    /// The group the selected workspace belongs to.
    public let groupId: UUID
    /// The group anchor workspace's current directory, or `nil` when the anchor
    /// is missing or has no directory. Keys the per-window group config lookup.
    public let anchorCwd: String?

    /// Creates a selected-workspace group membership projection.
    public init(selectedWorkspaceId: UUID, groupId: UUID, anchorCwd: String?) {
        self.selectedWorkspaceId = selectedWorkspaceId
        self.groupId = groupId
        self.anchorCwd = anchorCwd
    }
}
