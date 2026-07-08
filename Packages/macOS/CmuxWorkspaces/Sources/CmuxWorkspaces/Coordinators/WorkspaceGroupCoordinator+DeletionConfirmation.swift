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
        let includesAnchorWorkspace = model.tabs.contains { $0.id == group.anchorWorkspaceId }
        var memberWorkspaceIds = includesAnchorWorkspace ? [group.anchorWorkspaceId] : []
        memberWorkspaceIds.append(
            contentsOf: model.tabs.compactMap { tab in
                tab.groupId == groupId && tab.id != group.anchorWorkspaceId ? tab.id : nil
            }
        )
        return WorkspaceGroupDeletionConfirmation(
            groupId: group.id,
            groupName: group.name,
            anchorWorkspaceId: group.anchorWorkspaceId,
            includesAnchorWorkspace: includesAnchorWorkspace,
            memberWorkspaceIds: memberWorkspaceIds
        )
    }

    /// Deletes a group using the exact membership the user confirmed.
    ///
    /// Confirmation sheets run a nested modal loop, so other entrypoints can
    /// still mutate group membership before the user clicks the destructive
    /// button. This method closes only the workspaces present in the confirmed
    /// snapshot, then removes the group and detaches any later joiners instead
    /// of closing workspaces the dialog never showed.
    @discardableResult
    public func deleteWorkspaceGroup(
        confirmed confirmation: WorkspaceGroupDeletionConfirmation,
        recordHistory: Bool = true
    ) -> Int {
        guard let host else { return 0 }
        guard model.workspaceGroups.contains(where: { $0.id == confirmation.groupId }) else {
            return 0
        }

        let confirmedWorkspaceIds = Set(confirmation.memberWorkspaceIds)
        let members = model.tabs.filter { confirmedWorkspaceIds.contains($0.id) }
        let affectedWorkspaceIds = confirmation.memberWorkspaceIds.isEmpty
            ? model.tabs.contains(where: { $0.id == confirmation.anchorWorkspaceId }) ? [confirmation.anchorWorkspaceId] : []
            : confirmation.memberWorkspaceIds

        var closed = 0
        for tab in members {
            if model.tabs.count <= 1 {
                model.assignGroup(workspaceId: tab.id, groupId: nil)
                continue
            }
            let countBefore = model.tabs.count
            host.closeWorkspaceForGroupDeletion(tab, recordHistory: recordHistory)
            if model.tabs.count < countBefore { closed += 1 }
        }

        for tab in model.tabs where tab.groupId == confirmation.groupId {
            model.assignGroup(workspaceId: tab.id, groupId: nil)
        }
        model.workspaceGroups.removeAll { $0.id == confirmation.groupId }
        host.workspaceOrderDidChange(movedWorkspaceIds: affectedWorkspaceIds)
        return closed
    }
}
