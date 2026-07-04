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
        let memberIndices = workspaces.indices.filter { index in
            workspaces[index].groupId.map { subtreeGroupIds.contains($0) } ?? false
        }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = workspaces[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, workspaces.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
        let upper = min(lastIndex + 1, workspaces.count)
        return min(lower, upper)...max(lower, upper)
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
}
