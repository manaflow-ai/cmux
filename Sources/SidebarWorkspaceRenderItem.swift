import Foundation

/// One drawable item in the workspace sidebar.
///
/// `.workspace` carries an `effectiveGroupId` so the live reorder preview can
/// show a row indenting into (or out of) a group before the drop commits. It is
/// the group the row currently renders as a member of, which during a drag may
/// differ from `workspace.groupId` (the committed membership).
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    case workspace(Workspace, effectiveGroupId: UUID?)

    /// The workspace this item represents: the row's workspace, or a group
    /// header's anchor workspace.
    var representedWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace, _):
            return workspace.id
        }
    }

    /// The group the row renders as a member of (nil for top-level rows and
    /// group headers).
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
            // Share identity with the anchor workspace's row. The group header
            // *is* the anchor workspace's sidebar slot, so promoting a
            // workspace in place (or ungrouping) keeps the same ForEach
            // identity at that position and only swaps the row's content
            // between a `.workspace` row and a `.groupHeader`. That lets
            // SwiftUI animate the morph instead of insert+delete, and it stops
            // the LazyVStack from dropping the materialized row when the slot
            // changes kind — the bug that previously forced a whole-list
            // `.id(groupAnchorSignature)` rebuild (and reset sidebar scroll).
            return "workspace.\(group.anchorWorkspaceId.uuidString)"
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

    /// Returns the render list reordered to where the dragged row would land,
    /// so the `LazyVStack` can animate the gap open (and the dragged row's slot
    /// indent into/out of a group). Pure; drives the live reorder preview.
    ///
    /// - Parameters:
    ///   - items: the committed render list (`renderItems`).
    ///   - draggedWorkspaceId: the row being dragged, or nil when idle.
    ///   - dropIndicator: where the row would currently land.
    ///   - reorderWorkspaceIds: the ordered id scope the reorder operates over
    ///     (top-level rows when dragging a group anchor, otherwise every row).
    /// - Returns: the preview-ordered list, or `items` unchanged when there is
    ///   nothing to preview.
    static func dragPreviewItems(
        _ items: [SidebarWorkspaceRenderItem],
        draggedWorkspaceId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        reorderWorkspaceIds: [UUID],
        draggedMembershipGroupId: UUID? = nil
    ) -> [SidebarWorkspaceRenderItem] {
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
        let reordered = nextReorderIds.flatMap { blocksById[$0] ?? [] }
        return applyingDraggedMembership(
            reordered,
            draggedWorkspaceId: draggedWorkspaceId,
            membership: draggedMembershipGroupId
        )
    }

    /// Applies the membership the drag RESOLVED for the dragged row (interior
    /// slots force it, boundary slots follow the pointer's X axis) so the
    /// preview indent always matches what the drop will commit.
    private static func applyingDraggedMembership(
        _ renderItems: [SidebarWorkspaceRenderItem],
        draggedWorkspaceId: UUID,
        membership: UUID?
    ) -> [SidebarWorkspaceRenderItem] {
        guard let draggedIndex = renderItems.firstIndex(where: { item in
            if case .workspace(let workspace, _) = item { return workspace.id == draggedWorkspaceId }
            return false
        }) else {
            return renderItems
        }
        guard renderItems[draggedIndex].effectiveGroupId != membership else { return renderItems }
        var result = renderItems
        result[draggedIndex] = result[draggedIndex].withEffectiveGroupId(membership)
        return result
    }

    /// The id order after moving the dragged workspace to the indicator slot,
    /// or nil when the move is a no-op.
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

    /// Groups the render list into reorderable blocks keyed by the id that
    /// `reorderWorkspaceIds` orders. In top-level mode a group header plus its
    /// members form one block (so the whole group moves together), except the
    /// dragged member which is promoted to its own top-level block.
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
