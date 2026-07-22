public import Foundation

/// Current workspace-group membership used to confirm destructive group deletion.
public struct WorkspaceGroupDeletionConfirmation: Equatable, Sendable {
    /// The group's stable identity.
    public let groupId: UUID
    /// The group's current display name.
    public let groupName: String
    /// The workspace represented by the group header.
    public let anchorWorkspaceId: UUID
    /// Whether ``memberWorkspaceIds`` includes the anchor workspace.
    public let includesAnchorWorkspace: Bool
    /// Workspace identifiers that destructive deletion will close, in window order.
    public let memberWorkspaceIds: [UUID]

    /// Number of workspaces that destructive deletion would close.
    public var memberCount: Int { memberWorkspaceIds.count }

    /// Number of child workspaces inside the group, excluding the group header workspace.
    public var containedWorkspaceCount: Int {
        max(memberWorkspaceIds.count - (includesAnchorWorkspace ? 1 : 0), 0)
    }

    init(
        groupId: UUID,
        groupName: String,
        anchorWorkspaceId: UUID,
        includesAnchorWorkspace: Bool,
        memberWorkspaceIds: [UUID]
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.anchorWorkspaceId = anchorWorkspaceId
        self.includesAnchorWorkspace = includesAnchorWorkspace
        self.memberWorkspaceIds = memberWorkspaceIds
    }
}
