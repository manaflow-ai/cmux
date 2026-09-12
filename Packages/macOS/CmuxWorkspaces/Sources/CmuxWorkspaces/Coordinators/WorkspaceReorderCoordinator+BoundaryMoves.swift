public import Foundation

extension WorkspaceReorderCoordinator {
    // MARK: - Move to top

    /// Moves one workspace to the top of its pin tier.
    public func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    /// Moves the given workspaces to the top of their pin tiers, preserving
    /// their relative order (group members hoist behind their anchors).
    public func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = model.tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: selectedTabs.map(\.id))
            let topLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            let selectedTopLevelIds = model.topLevelWorkspaceIds(for: selectedTabs)
            let selectedTopLevelIdSet = Set(selectedTopLevelIds)
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            let desiredTopLevelIds =
                selectedTopLevelIds.filter { pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) } +
                selectedTopLevelIds.filter { !pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { !pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) }
            model.normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            model.syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: desiredTopLevelIds)
        } else {
            let remainingTabs = model.tabs.filter { !tabIds.contains($0.id) }
            let selectedPinned = selectedTabs.filter { $0.isPinned }
            let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
            let remainingPinned = remainingTabs.filter { $0.isPinned }
            let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
            model.tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    /// Moves a workspace to the top of the unpinned tier for a notification
    /// bump; no-ops for pinned rows or rows already at the boundary.
    public func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            guard let topLevelId = model.topLevelWorkspaceIds(for: [tab]).first else { return }
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return }
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [tabId])
            var desiredTopLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            guard let fromIndex = desiredTopLevelIds.firstIndex(of: topLevelId) else { return }
            let pinnedCount = desiredTopLevelIds.reduce(into: 0) { count, id in
                if pinnedTopLevelIds.contains(id) {
                    count += 1
                }
            }
            if fromIndex != pinnedCount {
                let movedId = desiredTopLevelIds.remove(at: fromIndex)
                desiredTopLevelIds.insert(movedId, at: min(pinnedCount, desiredTopLevelIds.count))
            }
            model.normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            model.syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: desiredTopLevelIds)
        } else {
            guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            let pinnedCount = model.tabs.filter { $0.isPinned }.count
            guard index != pinnedCount else { return }
            let tab = model.tabs[index]
            guard !tab.isPinned else { return }
            model.tabs.remove(at: index)
            model.tabs.insert(tab, at: pinnedCount)
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    /// Moves one workspace to the bottom of its tier and its group member run.
    public func moveTabToBottom(_ tabId: UUID) {
        moveTabsToBottom([tabId])
    }

    /// Whether moving this selection changes member or top-level row order.
    /// This reads the same plan as the mutation without publishing model changes.
    public func canMoveTabsToBottom(_ tabIds: Set<UUID>) -> Bool {
        bottomMovePlan(tabIds) != nil
    }

    /// Moves selected workspaces to the bottom, preserving selection order,
    /// group anchors, group membership, and top-level pin tiers.
    public func moveTabsToBottom(_ tabIds: Set<UUID>) {
        guard let plan = bottomMovePlan(tabIds) else { return }
        model.tabs = plan.tabs
        if let topLevelIds = plan.topLevelIds {
            model.normalizeWorkspaceGroupRunsPreservingOrder(topLevelIds)
            model.syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: topLevelIds)
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: plan.movedIds)
    }

    /// Plans both member and header movement, including durable empty group rows.
    private func bottomMovePlan(_ tabIds: Set<UUID>) -> (tabs: [Tab], topLevelIds: [UUID]?, movedIds: [UUID])? {
        guard !tabIds.isEmpty else { return nil }
        let selectedTabs = model.tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return nil }
        let movedIds = selectedTabs.map(\.id)
        if !model.workspaceGroups.isEmpty {
            let reordered = model.workspaceGroupMembersReordered(workspaceIds: movedIds, toBottom: true)
            let topLevelIds = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            let selectedIds = Set(model.topLevelWorkspaceIds(for: selectedTabs))
            let pinnedIds = model.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            let desiredIds = bottomTierOrder(topLevelIds, selectedIds: selectedIds, pinnedIds: pinnedIds)
            guard desiredIds != topLevelIds || reordered.map(\.id) != model.tabs.map(\.id) else { return nil }
            return (reordered, desiredIds, movedIds)
        }
        let currentIds = model.tabs.map(\.id)
        let pinnedIds = Set(model.tabs.filter(\.isPinned).map(\.id))
        let desiredIds = bottomTierOrder(currentIds, selectedIds: tabIds, pinnedIds: pinnedIds)
        guard desiredIds != currentIds else { return nil }
        let tabsById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        return (desiredIds.compactMap { tabsById[$0] }, nil, movedIds)
    }

    /// Stable partition within each pin tier; selected rows form its suffix.
    private func bottomTierOrder(_ ids: [UUID], selectedIds: Set<UUID>, pinnedIds: Set<UUID>) -> [UUID] {
        ids.filter { pinnedIds.contains($0) && !selectedIds.contains($0) } +
            ids.filter { pinnedIds.contains($0) && selectedIds.contains($0) } +
            ids.filter { !pinnedIds.contains($0) && !selectedIds.contains($0) } +
            ids.filter { !pinnedIds.contains($0) && selectedIds.contains($0) }
    }
}
