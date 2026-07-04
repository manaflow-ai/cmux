import CoreGraphics
import Foundation

extension SidebarWorkspaceReorderDropResolver {
    func legalInsertionRange(
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        explicitGroupId: UUID,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> ClosedRange<Int>? {
        guard let group = groupsById[explicitGroupId],
              draggedWorkspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let subtreeGroupIds = groupSubtreeIds(rootGroupId: explicitGroupId, groupsById: groupsById)
        let groupByAnchorId = Dictionary(uniqueKeysWithValues: groupsById.values.map { ($0.anchorWorkspaceId, $0) })
        let memberIndices = workspaces.indices.filter { index in
            workspaces[index].groupId.map { subtreeGroupIds.contains($0) } ?? false
        }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = workspaces[index]
            if member.id != group.anchorWorkspaceId,
               workspaceRowOccupiesPinnedParentSlot(
                   member,
                   explicitGroupId: explicitGroupId,
                   groupsById: groupsById,
                   groupByAnchorId: groupByAnchorId
               ) {
                count += 1
            }
        }
        if workspaceRowIsPinned(draggedWorkspace, groupByAnchorId: groupByAnchorId) {
            let lower = min(firstIndex + 1, workspaces.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
        let upper = min(lastIndex + 1, workspaces.count)
        return min(lower, upper)...max(lower, upper)
    }

    func renderedGroupScopedIndicator(
        request: SidebarWorkspaceReorderDropRequest,
        targetWorkspaceId: UUID,
        targetIndicator: SidebarDropIndicator,
        targetHeight: CGFloat?,
        legalRange: ClosedRange<Int>?,
        explicitGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> SidebarDropIndicator {
        let tabIds = request.workspaces.map(\.id)
        let pinnedTabIds = Set(request.workspaces.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        let planner = SidebarDropPlanner()
        let renderedIndicator = planner.indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: targetWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalRange,
            pointerY: pointerY(for: targetIndicator.edge, targetHeight: targetHeight),
            targetHeight: targetHeight,
            preserveTargetEdge: true
        ) ?? planner.indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: targetWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalRange,
            pointerY: pointerY(for: targetIndicator.edge, targetHeight: targetHeight),
            targetHeight: targetHeight,
            preserveTargetEdge: true,
            suppressesNoOp: false
        ) ?? targetIndicator
        let workspacesById = Dictionary(uniqueKeysWithValues: request.workspaces.map { ($0.id, $0) })
        return renderedGroupScopedIndicator(
            renderedIndicator,
            explicitGroupId: explicitGroupId,
            tabIds: tabIds,
            workspacesById: workspacesById,
            groupsById: groupsById
        )
    }

    private func renderedGroupScopedIndicator(
        _ indicator: SidebarDropIndicator,
        explicitGroupId: UUID,
        tabIds: [UUID],
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> SidebarDropIndicator {
        let subtreeGroupIds = groupSubtreeIds(rootGroupId: explicitGroupId, groupsById: groupsById)
        if let tabId = indicator.tabId,
           workspaceIsInGroupSubtree(tabId, workspacesById: workspacesById, subtreeGroupIds: subtreeGroupIds) {
            return indicator
        }

        let insertion: Int
        if let tabId = indicator.tabId,
           let index = tabIds.firstIndex(of: tabId) {
            insertion = indicator.edge == .bottom ? index + 1 : index
        } else {
            insertion = tabIds.count
        }
        let prefixEnd = min(max(insertion, 0), tabIds.count)
        guard prefixEnd > 0 else { return indicator }
        for tabId in tabIds[..<prefixEnd].reversed()
            where workspaceIsInGroupSubtree(tabId, workspacesById: workspacesById, subtreeGroupIds: subtreeGroupIds) {
            return SidebarDropIndicator(tabId: tabId, edge: .bottom)
        }
        return indicator
    }

    private func groupSubtreeIds(
        rootGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Set<UUID> {
        var childGroupIdsByParentId: [UUID: [UUID]] = [:]
        for group in groupsById.values {
            if let parentGroupId = group.parentGroupId {
                childGroupIdsByParentId[parentGroupId, default: []].append(group.id)
            }
        }
        var result: Set<UUID> = []
        var stack = [rootGroupId]
        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }
            stack.append(contentsOf: childGroupIdsByParentId[current] ?? [])
        }
        return result
    }

    private func workspaceRowOccupiesPinnedParentSlot(
        _ workspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        explicitGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Bool {
        if let directChildGroupId = directChildGroupId(
            containing: workspace,
            rootGroupId: explicitGroupId,
            groupsById: groupsById
        ) {
            return groupsById[directChildGroupId]?.isPinned == true
        }
        return workspaceRowIsPinned(workspace, groupByAnchorId: groupByAnchorId)
    }

    private func directChildGroupId(
        containing workspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        rootGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> UUID? {
        guard var currentGroupId = workspace.groupId else { return nil }
        var visited: Set<UUID> = []
        while let group = groupsById[currentGroupId],
              let parentGroupId = group.parentGroupId {
            guard visited.insert(currentGroupId).inserted else { return nil }
            if parentGroupId == rootGroupId {
                return currentGroupId
            }
            currentGroupId = parentGroupId
        }
        return nil
    }

    private func workspaceIsInGroupSubtree(
        _ workspaceId: UUID,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        subtreeGroupIds: Set<UUID>
    ) -> Bool {
        guard let groupId = workspacesById[workspaceId]?.groupId else { return false }
        return subtreeGroupIds.contains(groupId)
    }

    private func workspaceRowIsPinned(
        _ workspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Bool {
        groupByAnchorId[workspace.id]?.isPinned ?? workspace.isPinned
    }
}
