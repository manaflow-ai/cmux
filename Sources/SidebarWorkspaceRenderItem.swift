import Foundation

struct SidebarWorkspaceGroupDropPreview: Equatable {
    let draggedWorkspaceId: UUID
    let targetGroupId: UUID
}

/// One drawable item in the workspace sidebar.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    case workspace(Workspace, effectiveGroupId: UUID?)

    var representedWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace, _):
            return workspace.id
        }
    }

    var effectiveGroupId: UUID? {
        switch self {
        case .groupHeader:
            return nil
        case .workspace(_, let groupId):
            return groupId
        }
    }

    var id: String {
        switch self {
        case .groupHeader(let group, _):
            return "group.\(group.id.uuidString)"
        case .workspace(let workspace, _):
            return "workspace.\(workspace.id.uuidString)"
        }
    }

    func withEffectiveGroupId(_ groupId: UUID?) -> SidebarWorkspaceRenderItem {
        switch self {
        case .groupHeader:
            return self
        case .workspace(let workspace, _):
            return .workspace(workspace, effectiveGroupId: groupId)
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        var memberWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let gid = tab.groupId {
                memberWorkspaceIdsByGroupId[gid, default: []].append(tab.id)
            }
        }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            let groupId = tab.groupId
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        let memberWorkspaceIds = memberWorkspaceIdsByGroupId[groupId] ?? []
                        items.append(.groupHeader(group, memberWorkspaceIds: memberWorkspaceIds))
                        emittedHeaders.insert(groupId)
                        collapsedByGroupId[groupId] = group.isCollapsed
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = collapsedByGroupId[groupId] ?? false
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(tab, effectiveGroupId: groupId))
            }
        }
        return items
    }

    static func dragPreviewItems(
        _ items: [SidebarWorkspaceRenderItem],
        draggedWorkspaceId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        reorderWorkspaceIds: [UUID],
        groupDropPreview: SidebarWorkspaceGroupDropPreview?
    ) -> [SidebarWorkspaceRenderItem] {
        if let previewItems = groupDropPreviewItems(items, preview: groupDropPreview) {
            return previewItems
        }
        guard let draggedWorkspaceId,
              let dropIndicator,
              reorderWorkspaceIds.contains(draggedWorkspaceId),
              reorderWorkspaceIds.count > 1 else {
            return items
        }

        let topLevelMode = Set(reorderWorkspaceIds) != Set(items.map(\.representedWorkspaceId))
        let blocks = dragPreviewBlocks(
            items,
            reorderWorkspaceIds: reorderWorkspaceIds,
            draggedWorkspaceId: draggedWorkspaceId,
            topLevelMode: topLevelMode
        )
        let blockIds = blocks.map(\.workspaceId)
        let reorderIds = reorderWorkspaceIds.filter { blockIds.contains($0) }
        guard reorderIds.count == blocks.count,
              Set(reorderIds) == Set(blockIds),
              reorderIds.contains(draggedWorkspaceId),
              let nextReorderIds = dragPreviewWorkspaceIds(
                reorderIds,
                draggedWorkspaceId: draggedWorkspaceId,
                dropIndicator: dropIndicator
              ),
              nextReorderIds != reorderIds else {
            return items
        }

        var blocksById: [UUID: [SidebarWorkspaceRenderItem]] = [:]
        for block in blocks {
            guard blocksById[block.workspaceId] == nil else {
                return items
            }
            blocksById[block.workspaceId] = block.items
        }
        return nextReorderIds.flatMap { blocksById[$0] ?? [] }
    }

    private static func groupDropPreviewItems(
        _ items: [SidebarWorkspaceRenderItem],
        preview: SidebarWorkspaceGroupDropPreview?
    ) -> [SidebarWorkspaceRenderItem]? {
        guard let preview else { return nil }
        var draggedItem: SidebarWorkspaceRenderItem?
        var targetHeaderIndex: Int?
        var result: [SidebarWorkspaceRenderItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            switch item {
            case .groupHeader(let group, let memberWorkspaceIds)
                where group.id == preview.targetGroupId:
                let nextMemberWorkspaceIds = memberWorkspaceIds.contains(preview.draggedWorkspaceId)
                    ? memberWorkspaceIds
                    : memberWorkspaceIds + [preview.draggedWorkspaceId]
                targetHeaderIndex = result.count
                result.append(.groupHeader(group, memberWorkspaceIds: nextMemberWorkspaceIds))

            case .workspace(let workspace, _)
                where workspace.id == preview.draggedWorkspaceId:
                draggedItem = item.withEffectiveGroupId(preview.targetGroupId)

            case .groupHeader(let group, _)
                where group.anchorWorkspaceId == preview.draggedWorkspaceId:
                return nil

            default:
                result.append(item)
            }
        }

        guard let draggedItem, let targetHeaderIndex else { return nil }
        var insertionIndex = targetHeaderIndex + 1
        while insertionIndex < result.endIndex {
            guard result[insertionIndex].effectiveGroupId == preview.targetGroupId else {
                break
            }
            insertionIndex += 1
        }
        result.insert(draggedItem, at: insertionIndex)
        return result
    }

    private static func dragPreviewWorkspaceIds(
        _ ids: [UUID],
        draggedWorkspaceId: UUID,
        dropIndicator: SidebarDropIndicator
    ) -> [UUID]? {
        guard ids.contains(draggedWorkspaceId) else { return nil }
        if dropIndicator.tabId == draggedWorkspaceId {
            return ids
        }

        var result = ids.filter { $0 != draggedWorkspaceId }
        let insertionIndex: Int
        if let targetWorkspaceId = dropIndicator.tabId {
            guard let targetIndex = result.firstIndex(of: targetWorkspaceId) else {
                return ids
            }
            insertionIndex = dropIndicator.edge == .top ? targetIndex : targetIndex + 1
        } else {
            insertionIndex = result.count
        }

        result.insert(draggedWorkspaceId, at: min(max(insertionIndex, 0), result.count))
        return result
    }

    private static func dragPreviewBlocks(
        _ items: [SidebarWorkspaceRenderItem],
        reorderWorkspaceIds: [UUID],
        draggedWorkspaceId: UUID,
        topLevelMode: Bool
    ) -> [(workspaceId: UUID, items: [SidebarWorkspaceRenderItem])] {
        guard topLevelMode else {
            return items.map { item in
                (workspaceId: item.representedWorkspaceId, items: [item])
            }
        }

        let reorderIdSet = Set(reorderWorkspaceIds)
        var blocks: [(workspaceId: UUID, items: [SidebarWorkspaceRenderItem])] = []
        var index = items.startIndex
        while index < items.endIndex {
            switch items[index] {
            case .groupHeader(let group, _):
                var groupItems = [items[index]]
                var promotedMemberItems: [SidebarWorkspaceRenderItem] = []
                index = items.index(after: index)
                while index < items.endIndex {
                    guard case .workspace(let workspace, _) = items[index],
                          workspace.groupId == group.id else {
                        break
                    }
                    if workspace.id == draggedWorkspaceId, reorderIdSet.contains(workspace.id) {
                        promotedMemberItems.append(items[index].withEffectiveGroupId(nil))
                    } else {
                        groupItems.append(items[index])
                    }
                    index = items.index(after: index)
                }
                blocks.append((workspaceId: group.anchorWorkspaceId, items: groupItems))
                for item in promotedMemberItems {
                    blocks.append((workspaceId: item.representedWorkspaceId, items: [item]))
                }

            case .workspace(let workspace, _):
                blocks.append((workspaceId: workspace.id, items: [items[index]]))
                index = items.index(after: index)
            }
        }
        return blocks
    }
}
