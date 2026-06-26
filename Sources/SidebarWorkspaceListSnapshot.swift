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

    init(tabs: [Workspace], workspaceGroups: [WorkspaceGroup]) {
        self.tabs = tabs
        self.tabIds = tabs.map(\.id)
        workspaceCount = tabs.count
        tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        workspaceGroupIdByWorkspaceId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        self.workspaceGroups = workspaceGroups
        workspaceGroupById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        workspaceGroupByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        workspaceGroupAnchorIds = Set(workspaceGroups.map(\.anchorWorkspaceId))
        workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        pinResolutionContext = WorkspaceActionDispatcher.PinResolutionContext(
            workspacesById: workspaceById,
            liveWorkspaceIds: Set(tabIds)
        )
        topLevelWorkspaceIds = Self.makeTopLevelWorkspaceIds(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        topLevelPinnedWorkspaceIds = Set(topLevelWorkspaceIds.filter { id in
            if let group = workspaceGroupByAnchorId[id] {
                return group.isPinned
            }
            return workspaceById[id]?.isPinned == true
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
        return topLevelPinnedWorkspaceIds
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

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
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
        ids.insert(promotedWorkspaceId, at: min(groupIndex + 1, ids.count))
        return ids
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
