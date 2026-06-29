import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Immutable sidebar topology derived from `TabManager.tabs` and workspace groups.
@MainActor
final class SidebarWorkspaceListSnapshot {
    let tabs: [Workspace]
    let tabIds: [UUID]
    let workspaceCount: Int
    let tabIndexById: [UUID: Int]
    let workspaceById: [UUID: Workspace]
    let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    let workspaceGroups: [WorkspaceGroup]
    let workspaceGroupById: [UUID: WorkspaceGroup]
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let workspaceRenderItems: [SidebarWorkspaceRenderItem]
    let visibleWorkspaceRowIds: [UUID]
    let pinResolutionContext: WorkspaceActionDispatcher.PinResolutionContext

    private let workspaceGroupByAnchorId: [UUID: WorkspaceGroup]
    private let workspaceGroupAnchorIds: Set<UUID>
    private let topLevelWorkspaceIds: [UUID]
    private let topLevelPinnedWorkspaceIds: Set<UUID>
    private let fullRowPinnedWorkspaceIds: Set<UUID>
    private let visibleWorkspaceRowIdSet: Set<UUID>

    init(tabs: [Workspace], workspaceGroups: [WorkspaceGroup]) {
        self.tabs = tabs
        self.tabIds = tabs.map(\.id)
        workspaceCount = tabs.count
        tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        workspaceById = workspacesById
        workspaceGroupIdByWorkspaceId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        self.workspaceGroups = workspaceGroups
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        workspaceGroupById = groupsById
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        workspaceGroupByAnchorId = groupsByAnchorId
        workspaceGroupAnchorIds = Set(workspaceGroups.map(\.anchorWorkspaceId))
        workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: groupsById
        )
        visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        visibleWorkspaceRowIdSet = Set(visibleWorkspaceRowIds)
        pinResolutionContext = WorkspaceActionDispatcher.PinResolutionContext(
            workspacesById: workspacesById,
            liveWorkspaceIds: Set(tabIds)
        )
        topLevelWorkspaceIds = Self.makeTopLevelWorkspaceIds(
            tabs: tabs,
            groupsById: groupsById
        )
        topLevelPinnedWorkspaceIds = Set(topLevelWorkspaceIds.filter { id in
            if let group = groupsByAnchorId[id] {
                return group.isPinned
            }
            return workspacesById[id]?.isPinned == true
        })
        fullRowPinnedWorkspaceIds = Set(tabs.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
    }

    func orderedWorkspaces(for workspaceIds: Set<UUID>) -> [Workspace] {
        guard !workspaceIds.isEmpty else { return [] }
        return workspaceIds
            .compactMap { workspaceById[$0] }
            .sorted {
                (tabIndexById[$0.id] ?? Int.max) < (tabIndexById[$1.id] ?? Int.max)
            }
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return tabIds
        }
        return topLevelWorkspaceIdsForReorder(promotingWorkspaceId: draggedWorkspaceId)
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return fullRowPinnedWorkspaceIds
        }
        return topLevelPinnedWorkspaceIdsForReorder(promotingWorkspaceId: draggedWorkspaceId)
    }

    func sidebarDropIndicatorRowIds(
        draggedWorkspaceId: UUID,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> [UUID] {
        switch scope {
        case .raw:
            return tabIds
        case .topLevel:
            return topLevelWorkspaceIdsForReorder(promotingWorkspaceId: draggedWorkspaceId)
        case .group(let groupId):
            guard workspaceGroupById[groupId] != nil else { return [] }
            return tabs.compactMap { tab in
                tab.groupId == groupId && visibleWorkspaceRowIdSet.contains(tab.id) ? tab.id : nil
            }
        }
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        if workspaceGroupAnchorIds.contains(draggedWorkspaceId) ||
            targetWorkspaceId.map(workspaceGroupAnchorIds.contains) == true {
            return true
        }
        guard let draggedWorkspaceGroupId = workspaceGroupIdByWorkspaceId[draggedWorkspaceId],
              draggedWorkspaceGroupId != nil else {
            return false
        }
        guard let targetWorkspaceId else { return true }
        guard let targetWorkspaceGroupId = workspaceGroupIdByWorkspaceId[targetWorkspaceId] else {
            return false
        }
        return targetWorkspaceGroupId == nil
    }

    private func topLevelWorkspaceIdsForReorder(promotingWorkspaceId promotedWorkspaceId: UUID?) -> [UUID] {
        guard let promotedWorkspaceId,
              !topLevelWorkspaceIds.contains(promotedWorkspaceId),
              let tab = workspaceById[promotedWorkspaceId],
              let groupId = tab.groupId,
              let group = workspaceGroupById[groupId],
              let groupIndex = topLevelWorkspaceIds.firstIndex(of: group.anchorWorkspaceId) else {
            return topLevelWorkspaceIds
        }
        var ids = topLevelWorkspaceIds
        ids.insert(
            promotedWorkspaceId,
            at: promotedTopLevelInsertionIndex(
                ids: ids,
                groupIndex: groupIndex,
                promotedIsPinned: tab.isPinned
            )
        )
        return ids
    }

    private func topLevelPinnedWorkspaceIdsForReorder(promotingWorkspaceId promotedWorkspaceId: UUID?) -> Set<UUID> {
        guard promotedWorkspaceId != nil else { return topLevelPinnedWorkspaceIds }
        return Set(topLevelWorkspaceIdsForReorder(promotingWorkspaceId: promotedWorkspaceId).filter {
            topLevelWorkspaceIdIsPinned($0)
        })
    }

    private func promotedTopLevelInsertionIndex(
        ids: [UUID],
        groupIndex: Int,
        promotedIsPinned: Bool
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let pinnedCount = ids.reduce(into: 0) { count, id in
            if topLevelWorkspaceIdIsPinned(id) {
                count += 1
            }
        }
        return promotedIsPinned ? min(desiredIndex, pinnedCount) : max(desiredIndex, pinnedCount)
    }

    private func topLevelWorkspaceIdIsPinned(_ id: UUID) -> Bool {
        if let group = workspaceGroupByAnchorId[id] {
            return group.isPinned
        }
        return workspaceById[id]?.isPinned == true
    }

    private static func makeTopLevelWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        return ids
    }
}
