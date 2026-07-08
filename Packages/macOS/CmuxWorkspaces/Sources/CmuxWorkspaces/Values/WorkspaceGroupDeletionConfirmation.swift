public import Foundation

/// Current workspace-group membership used to confirm destructive group deletion.
public struct WorkspaceGroupDeletionConfirmation: Equatable, Sendable {
    /// The group's stable identity.
    public let groupId: UUID
    /// The group's current display name.
    public let groupName: String
    /// Live member workspace identifiers in window order.
    public let memberWorkspaceIds: [UUID]

    /// Number of live workspace members that deletion would close.
    public var memberCount: Int { memberWorkspaceIds.count }

    init(groupId: UUID, groupName: String, memberWorkspaceIds: [UUID]) {
        self.groupId = groupId
        self.groupName = groupName
        self.memberWorkspaceIds = memberWorkspaceIds
    }
}
