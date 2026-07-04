public import Foundation

// Sidebar ordering reads and reorder-index clamps over the model's own
// tabs/groups storage, lifted one-for-one from the legacy private TabManager
// helpers. All are pure reads; mutating flows live on the coordinators.
extension WorkspacesModel {
    /// Whether the workspace anchors any group.
    public func isWorkspaceGroupAnchor(_ workspaceId: UUID) -> Bool {
        workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
    }

    /// Whether the workspace anchors a root-level group.
    func isRootWorkspaceGroupAnchor(_ workspaceId: UUID) -> Bool {
        guard let group = workspaceGroups.first(where: { $0.anchorWorkspaceId == workspaceId }) else {
            return false
        }
        return rootWorkspaceGroup(containing: group.id)?.id == group.id
    }

    /// The root folder that contains `groupId`, or nil when the group is unknown.
    func rootWorkspaceGroup(containing groupId: UUID) -> WorkspaceGroup? {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        return rootWorkspaceGroup(containing: groupId, groupsById: groupsById)
    }

    /// The root folder that contains `groupId`, using a prebuilt group map.
    func rootWorkspaceGroup(containing groupId: UUID, groupsById: [UUID: WorkspaceGroup]) -> WorkspaceGroup? {
        guard var root = groupsById[groupId] else { return nil }
        var visited: Set<UUID> = [root.id]
        while let parentId = root.parentGroupId,
              let parent = groupsById[parentId],
              visited.insert(parent.id).inserted {
            root = parent
        }
        return root
    }

    /// Whether assigning `parentGroupId` as `groupId`'s parent would keep the
    /// folder tree valid.
    public func canSetWorkspaceGroupParent(groupId: UUID, parentGroupId: UUID?) -> Bool {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        return canSetWorkspaceGroupParent(
            groupId: groupId,
            parentGroupId: parentGroupId,
            groupsById: groupsById
        )
    }

    /// Whether assigning `parentGroupId` as `groupId`'s parent would keep the
    /// folder tree valid, using a prebuilt group map for hot normalization paths.
    func canSetWorkspaceGroupParent(
        groupId: UUID,
        parentGroupId: UUID?,
        groupsById: [UUID: WorkspaceGroup]
    ) -> Bool {
        guard groupsById[groupId] != nil else { return false }
        guard let parentGroupId else { return true }
        guard parentGroupId != groupId,
              groupsById[parentGroupId] != nil else {
            return false
        }
        var visited: Set<UUID> = []
        var cursor: UUID? = parentGroupId
        while let current = cursor {
            guard visited.insert(current).inserted else { return false }
            if current == groupId { return false }
            cursor = groupsById[current]?.parentGroupId
        }
        return true
    }

    /// Group ids in `groupId`'s subtree, including `groupId`.
    public func workspaceGroupSubtreeGroupIds(groupId: UUID) -> Set<UUID> {
        var childrenByParentId: [UUID: [UUID]] = [:]
        for group in workspaceGroups {
            if let parentGroupId = group.parentGroupId {
                childrenByParentId[parentGroupId, default: []].append(group.id)
            }
        }

        var result: Set<UUID> = []
        var stack: [UUID] = [groupId]
        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }
            stack.append(contentsOf: childrenByParentId[current] ?? [])
        }
        return result
    }

    /// Workspace ids contained by `groupId` and any nested child groups, in tab order.
    public func workspaceGroupSubtreeWorkspaceIds(groupId: UUID) -> [UUID] {
        let groupIds = workspaceGroupSubtreeGroupIds(groupId: groupId)
        return tabs.compactMap { tab in
            guard let tabGroupId = tab.groupId,
                  groupIds.contains(tabGroupId) else { return nil }
            return tab.id
        }
    }

    /// The top-level sidebar row id for each given workspace (its group's
    /// anchor when grouped, itself when ungrouped), deduplicated in order.
    func topLevelWorkspaceIds(for workspaces: [Tab]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            let topLevelId: UUID
            if let groupId = workspace.groupId,
               let root = rootWorkspaceGroup(containing: groupId, groupsById: groupsById) {
                topLevelId = root.anchorWorkspaceId
            } else {
                topLevelId = workspace.id
            }
            if emittedIds.insert(topLevelId).inserted {
                ids.append(topLevelId)
            }
        }
        return ids
    }

    /// The sidebar's top-level row ids in `tabs[]` order (group anchors and
    /// ungrouped workspaces). Optionally inserts a grouped workspace being
    /// promoted to top level as close to its group's row as its pin tier allows.
    func sidebarTopLevelWorkspaceIds(promotingWorkspaceId promotedWorkspaceId: UUID? = nil) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedRootGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let rootGroup = rootWorkspaceGroup(containing: groupId, groupsById: groupsById) {
                if emittedRootGroupIds.insert(rootGroup.id).inserted {
                    ids.append(rootGroup.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        if let promotedWorkspaceId,
           !ids.contains(promotedWorkspaceId),
           let tab = tabsById[promotedWorkspaceId],
           let groupId = tab.groupId,
           let rootGroup = rootWorkspaceGroup(containing: groupId, groupsById: groupsById),
           let groupIndex = ids.firstIndex(of: rootGroup.anchorWorkspaceId) {
            ids.insert(
                promotedWorkspaceId,
                at: promotedTopLevelInsertionIndex(
                    ids: ids,
                    groupIndex: groupIndex,
                    promotedIsPinned: tab.isPinned,
                    tabsById: tabsById,
                    groupsByAnchorId: groupsByAnchorId
                )
            )
        }
        return ids
    }

    /// Projects a desired full workspace-id order down to top-level row ids,
    /// appending any unmentioned workspaces in `tabs[]` order.
    func topLevelWorkspaceIdsPreservingOrder(_ desiredIds: [UUID]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedWorkspaceIds = Set<UUID>()
        var emittedRootGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)

        func appendTopLevelId(for id: UUID) {
            guard let tab = tabsById[id],
                  emittedWorkspaceIds.insert(tab.id).inserted else { return }
            if let groupId = tab.groupId,
               let rootGroup = rootWorkspaceGroup(containing: groupId, groupsById: groupsById) {
                if emittedRootGroupIds.insert(rootGroup.id).inserted {
                    ids.append(rootGroup.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }

        for id in desiredIds {
            appendTopLevelId(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendTopLevelId(for: tab.id)
        }
        return ids
    }

    /// The pinned subset of the top-level rows (pinned groups by group pin,
    /// ungrouped workspaces by workspace pin).
    func sidebarTopLevelPinnedWorkspaceIds(promotingWorkspaceId: UUID? = nil) -> Set<UUID> {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return Set(sidebarTopLevelWorkspaceIds(promotingWorkspaceId: promotingWorkspaceId).filter { id in
            topLevelWorkspaceIdIsPinned(id, tabsById: tabsById, groupsByAnchorId: groupsByAnchorId)
        })
    }

    private func promotedTopLevelInsertionIndex(
        ids: [UUID],
        groupIndex: Int,
        promotedIsPinned: Bool,
        tabsById: [UUID: Tab],
        groupsByAnchorId: [UUID: WorkspaceGroup]
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let pinnedCount = ids.reduce(into: 0) { count, id in
            if topLevelWorkspaceIdIsPinned(id, tabsById: tabsById, groupsByAnchorId: groupsByAnchorId) {
                count += 1
            }
        }
        return promotedIsPinned ? min(desiredIndex, pinnedCount) : max(desiredIndex, pinnedCount)
    }

    private func topLevelWorkspaceIdIsPinned(
        _ id: UUID,
        tabsById: [UUID: Tab],
        groupsByAnchorId: [UUID: WorkspaceGroup]
    ) -> Bool {
        if let group = groupsByAnchorId[id] {
            return group.isPinned
        }
        return tabsById[id]?.isPinned == true
    }

    /// Clamps a requested top-level reorder index into the mover's pin tier.
    func clampedTopLevelReorderIndex(
        forWorkspaceId workspaceId: UUID,
        targetIndex: Int,
        topLevelIds: [UUID],
        promotingWorkspaceId: UUID? = nil
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, topLevelIds.count - 1)))
        let pinnedIds = sidebarTopLevelPinnedWorkspaceIds(promotingWorkspaceId: promotingWorkspaceId)
        let pinnedCount = topLevelIds.reduce(into: 0) { count, id in
            if pinnedIds.contains(id) {
                count += 1
            }
        }
        if pinnedIds.contains(workspaceId) {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    /// Helper for `normalizeWorkspaceGroupContiguity`: hoist the anchor to
    /// the front of its group's member list, then keep pinned member
    /// workspaces above unpinned member workspaces while preserving relative
    /// order inside each tier. No-op when the anchor isn't actually in the
    /// list (anchor lifecycle elsewhere ensures it always should be).
    func anchorFirst(_ members: [Tab], anchorId: UUID) -> [Tab] {
        guard let anchorIndex = members.firstIndex(where: { $0.id == anchorId }) else {
            return members
        }
        let anchor = members[anchorIndex]
        let nonAnchors = members.filter { $0.id != anchorId }
        return [anchor] + nonAnchors.filter(\.isPinned) + nonAnchors.filter { !$0.isPinned }
    }

    /// Clamps a requested reorder index for a workspace into its legal range
    /// (group section for grouped members, pin tier globally).
    func clampedReorderIndex(for workspace: Tab, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        if let groupClamp = clampedGroupedMemberReorderIndex(
            for: workspace,
            clampedTargetIndex: clamped
        ) {
            return groupClamp
        }
        let pinnedCount = leadingGlobalPinnedRowCount()
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    /// The in-group clamp for a non-anchor member reorder, or `nil` when the
    /// workspace is ungrouped or its group's anchor.
    func clampedGroupedMemberReorderIndex(
        for workspace: Tab,
        clampedTargetIndex: Int
    ) -> Int? {
        guard let groupId = workspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              workspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        let lowerBound = workspace.isPinned
            ? min(firstIndex + 1, lastIndex)
            : min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount, lowerBound)
            : lastIndex
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }

    /// The number of leading rows in `tabs[]` that render as pinned.
    func leadingGlobalPinnedRowCount() -> Int {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var count = 0
        for tab in tabs {
            guard isGlobalPinnedRow(tab, groupsById: groupsById) else { break }
            count += 1
        }
        return count
    }

    /// Whether the row renders as pinned: root group pin for grouped members,
    /// workspace pin otherwise.
    func isGlobalPinnedRow(_ tab: Tab) -> Bool {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        return isGlobalPinnedRow(tab, groupsById: groupsById)
    }

    private func isGlobalPinnedRow(_ tab: Tab, groupsById: [UUID: WorkspaceGroup]) -> Bool {
        if let groupId = tab.groupId,
           let group = rootWorkspaceGroup(containing: groupId, groupsById: groupsById) {
            return group.isPinned
        }
        return tab.isPinned
    }
}
