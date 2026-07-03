public import CmuxFoundation
public import Foundation

/// Immutable sidebar topology derived from workspaces and workspace groups.
@MainActor
public final class SidebarWorkspaceListSnapshot<Tab: WorkspaceTabRepresenting> {
    /// The workspaces in storage order.
    public let tabs: [Tab]
    /// The workspace ids in storage order.
    public let tabIds: [UUID]
    /// The number of workspaces in the snapshot.
    public let workspaceCount: Int
    /// Workspace indices keyed by workspace id.
    public let tabIndexById: [UUID: Int]
    /// Workspaces keyed by workspace id.
    public let workspaceById: [UUID: Tab]
    /// Workspace group ids keyed by workspace id.
    public let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    /// The workspace groups in sidebar order.
    public let workspaceGroups: [WorkspaceGroup]
    /// Workspace groups keyed by group id.
    public let workspaceGroupById: [UUID: WorkspaceGroup]
    /// Context-menu group entries in sidebar order.
    public let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    /// Visible workspace-sidebar render items.
    public let workspaceRenderItems: [SidebarWorkspaceRenderItem<Tab>]
    /// Visible row workspace ids used by drop-indicator planning.
    public let visibleWorkspaceRowIds: [UUID]

    private let workspaceGroupByAnchorId: [UUID: WorkspaceGroup]
    private let workspaceGroupAnchorIds: Set<UUID>
    private let topLevelWorkspaceIds: [UUID]
    private let topLevelPinnedWorkspaceIds: Set<UUID>
    private let fullRowPinnedWorkspaceIds: Set<UUID>
    private let visibleWorkspaceRowIdSet: Set<UUID>

    /// Creates a snapshot from the current workspace and group topology.
    /// - Parameters:
    ///   - tabs: The workspaces in storage order.
    ///   - workspaceGroups: The workspace groups in sidebar order.
    public init(tabs: [Tab], workspaceGroups: [WorkspaceGroup]) {
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

    /// Returns workspaces from `workspaceIds`, sorted by the snapshot's storage order.
    /// - Parameter workspaceIds: The workspace ids to resolve.
    /// - Returns: The matching workspaces in storage order.
    public func orderedWorkspaces(for workspaceIds: Set<UUID>) -> [Tab] {
        guard !workspaceIds.isEmpty else { return [] }
        return workspaceIds
            .compactMap { workspaceById[$0] }
            .sorted {
                (tabIndexById[$0.id] ?? Int.max) < (tabIndexById[$1.id] ?? Int.max)
            }
    }

    /// Returns the row-id space a sidebar drag should plan in.
    /// - Parameters:
    ///   - draggedWorkspaceId: The dragged workspace id, when any.
    ///   - targetWorkspaceId: The target workspace id, when any.
    ///   - usesTopLevelRows: Whether top-level rows are already known to be required.
    /// - Returns: Full raw workspace row ids or top-level row ids.
    public func sidebarReorderWorkspaceIds(
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

    /// Returns the pinned subset for the row-id space a sidebar drag should plan in.
    /// - Parameters:
    ///   - draggedWorkspaceId: The dragged workspace id, when any.
    ///   - targetWorkspaceId: The target workspace id, when any.
    ///   - usesTopLevelRows: Whether top-level rows are already known to be required.
    /// - Returns: Pinned workspace ids in the chosen row-id space.
    public func sidebarReorderPinnedWorkspaceIds(
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

    /// Returns the visible row ids a drop indicator should use for one drag scope.
    /// - Parameters:
    ///   - draggedWorkspaceId: The dragged workspace id.
    ///   - scope: The resolved drop-indicator scope.
    /// - Returns: Visible row workspace ids for the scope.
    public func sidebarDropIndicatorRowIds(
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

    /// Whether a sidebar drag plans in top-level rows.
    /// - Parameters:
    ///   - draggedWorkspaceId: The dragged workspace id, when any.
    ///   - targetWorkspaceId: The target workspace id, when any.
    /// - Returns: `true` when group rows or a grouped-child promotion are involved.
    public func sidebarReorderUsesTopLevelRows(
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
        tabs: [Tab],
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
