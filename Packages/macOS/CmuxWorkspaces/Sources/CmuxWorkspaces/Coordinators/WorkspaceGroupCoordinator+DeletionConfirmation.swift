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
        let liveAnchorId = group.liveAnchorWorkspaceId
        let includesAnchorWorkspace = liveAnchorId.map { anchorId in
            model.tabs.contains { $0.id == anchorId }
        } ?? false
        var memberWorkspaceIds: [UUID] = {
            guard includesAnchorWorkspace, let liveAnchorId else { return [] }
            return [liveAnchorId]
        }()
        memberWorkspaceIds.append(
            contentsOf: model.tabs.compactMap { tab in
                tab.groupId == groupId && tab.id != group.liveAnchorWorkspaceId ? tab.id : nil
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

    /// Resolves delete intent from a rendered group header.
    ///
    /// The sidebar header row can briefly outlive the backing group record
    /// while SwiftUI drains an old list snapshot. From the user's perspective
    /// the folder is still on screen and its Delete Group menu item must delete
    /// that visible header workspace instead of no-oping on the stale group id.
    public func deletionConfirmation(
        groupId: UUID,
        fallbackGroupName: String,
        fallbackAnchorWorkspaceId: UUID
    ) -> WorkspaceGroupDeletionConfirmation? {
        if let confirmation = deletionConfirmation(groupId: groupId) {
            return confirmation
        }
        guard model.tabs.contains(where: { $0.id == fallbackAnchorWorkspaceId }) else {
            return nil
        }
        return WorkspaceGroupDeletionConfirmation(
            groupId: groupId,
            groupName: fallbackGroupName,
            anchorWorkspaceId: fallbackAnchorWorkspaceId,
            includesAnchorWorkspace: true,
            memberWorkspaceIds: [fallbackAnchorWorkspaceId]
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
        guard model.workspaceGroups.contains(where: { $0.id == confirmation.groupId })
            || model.tabs.contains(where: { $0.id == confirmation.anchorWorkspaceId }) else {
            return 0
        }

        let confirmedWorkspaceIds = Set(confirmation.memberWorkspaceIds)
        let confirmedOrder = Dictionary(
            uniqueKeysWithValues: confirmation.memberWorkspaceIds.enumerated().map { ($1, $0) }
        )
        // Drain the group's *live* anchor last. The snapshot's anchor can go
        // stale: another entrypoint may close it during the nested modal loop,
        // which promotes the next member to anchor. Closing that live anchor
        // mid-batch would re-promote and renormalize the whole collection on
        // every step — the O(k x totalTabs) main-actor churn TabManager's
        // `anchorLastCloseOrder` exists to avoid. Resolve the current anchor
        // (falling back to the snapshot when the group is already gone) and sort
        // it last, so each non-anchor close stays cheap and at most one
        // promotion runs before the group is torn down.
        let liveAnchorId = model.workspaceGroups
            .first(where: { $0.id == confirmation.groupId })?
            .anchorWorkspaceId ?? confirmation.anchorWorkspaceId
        var members = model.tabs.filter { confirmedWorkspaceIds.contains($0.id) }
        members.sort { lhs, rhs in
            if lhs.id == liveAnchorId { return false }
            if rhs.id == liveAnchorId { return true }
            return confirmedOrder[lhs.id, default: Int.max] < confirmedOrder[rhs.id, default: Int.max]
        }
        let affectedWorkspaceIds = confirmation.memberWorkspaceIds.isEmpty
            ? model.tabs.contains(where: { $0.id == confirmation.anchorWorkspaceId }) ? [confirmation.anchorWorkspaceId] : []
            : confirmation.memberWorkspaceIds

        var closed = 0
        for tab in members {
            if model.tabs.count <= 1 {
                _ = host.createWorkspaceForGroup(
                    title: nil,
                    workingDirectory: nil,
                    initialSurface: .terminal,
                    initialBrowserURL: nil,
                    initialBrowserOmnibarVisible: false,
                    initialBrowserTransparentBackground: false,
                    inheritWorkingDirectory: true,
                    select: true,
                    applyCreationTitleAsCustomTitle: true
                )
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
