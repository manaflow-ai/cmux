public import Foundation

extension WorkspaceGroupCoordinator {
    /// Resolves the live confirmation snapshot for deleting a workspace group.
    ///
    /// Membership is read from the authoritative `WorkspaceTabRepresenting.groupId`
    /// values at action time, so stale sidebar render snapshots cannot drive the
    /// destructive confirmation copy or delete follow-through.
    /// - Parameter groupId: The group being considered for deletion.
    /// - Returns: The current confirmation snapshot, or `nil` if the group no longer exists.
    public func deletionConfirmation(groupId: UUID) -> WorkspaceGroupDeletionConfirmation? {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        let memberWorkspaceIds = model.tabs.compactMap { tab in
            tab.groupId == groupId ? tab.id : nil
        }
        return WorkspaceGroupDeletionConfirmation(
            groupId: group.id,
            groupName: group.name,
            memberWorkspaceIds: memberWorkspaceIds
        )
    }
}
