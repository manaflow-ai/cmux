public import Foundation

extension WorkspaceGroupCoordinator {
    /// UI-only collapse toggle that moves hidden focus to the group's anchor.
    public func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else { return }
        applyWorkspaceGroupDisclosure(groupIds: [groupId], isCollapsed: !group.isCollapsed)
    }

    /// Collapses every group and reconciles hidden sidebar selection once.
    public func collapseAllWorkspaceGroups() {
        applyWorkspaceGroupDisclosure(
            groupIds: Set(model.workspaceGroups.map(\.id)),
            isCollapsed: true
        )
    }

    /// Expands every group without changing selection.
    public func expandAllWorkspaceGroups() {
        applyWorkspaceGroupDisclosure(
            groupIds: Set(model.workspaceGroups.map(\.id)),
            isCollapsed: false
        )
    }

    /// Pure data mutation for socket/CLI paths that must preserve focus.
    public func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }),
              model.workspaceGroups[index].isCollapsed != isCollapsed else { return }
        model.workspaceGroups[index].isCollapsed = isCollapsed
    }

    private func applyWorkspaceGroupDisclosure(groupIds: Set<UUID>, isCollapsed: Bool) {
        guard let host else { return }
        let targetGroups = model.workspaceGroups.filter { groupIds.contains($0.id) }
        guard !targetGroups.isEmpty else { return }
        let targetGroupsById = Dictionary(uniqueKeysWithValues: targetGroups.map { ($0.id, $0) })
        let changingGroupIds = Set(targetGroups.filter { $0.isCollapsed != isCollapsed }.map(\.id))

        if isCollapsed {
            let hiddenMemberIds = Set(model.tabs.compactMap { tab -> UUID? in
                guard let groupId = tab.groupId,
                      let group = targetGroupsById[groupId],
                      let liveAnchorWorkspaceId = group.liveAnchorWorkspaceId,
                      liveAnchorWorkspaceId != tab.id else { return nil }
                return tab.id
            })

            var focusedWorkspaceId: UUID?
            if let selectedTabId = model.selectedTabId,
               let selectedGroupId = model.tabs.first(where: { $0.id == selectedTabId })?.groupId,
               let selectedGroup = targetGroupsById[selectedGroupId],
               let liveAnchorWorkspaceId = selectedGroup.liveAnchorWorkspaceId {
                if liveAnchorWorkspaceId == selectedTabId {
                    focusedWorkspaceId = selectedTabId
                } else if let anchor = model.tabs.first(where: { $0.id == liveAnchorWorkspaceId }) {
                    host.selectWorkspace(anchor)
                    focusedWorkspaceId = anchor.id
                }
            }

            if !hiddenMemberIds.isEmpty,
               (!host.sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenMemberIds)
                || focusedWorkspaceId != nil) {
                host.subtractSidebarSelection(
                    hiddenWorkspaceIds: hiddenMemberIds,
                    focusedWorkspaceId: focusedWorkspaceId
                )
            }
        }

        guard !changingGroupIds.isEmpty else { return }
        var groups = model.workspaceGroups
        for index in groups.indices where changingGroupIds.contains(groups[index].id) {
            groups[index].isCollapsed = isCollapsed
        }
        model.workspaceGroups = groups
    }
}
