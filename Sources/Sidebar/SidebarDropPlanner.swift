import CoreGraphics
import Foundation

enum SidebarDropEdge: Equatable {
    case top
    case bottom
}

struct SidebarDropIndicator: Equatable {
    let tabId: UUID?
    let edge: SidebarDropEdge
}

enum SidebarDropPlanner {
    static func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil
    ) -> SidebarDropIndicator? {
        guard tabIds.count > 1, let draggedTabId else { return nil }
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge: SidebarDropEdge
            if let pointerY, let targetHeight {
                edge = edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
            } else {
                edge = preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            }
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        let legalInsertionPosition = legalInsertionPosition(
            draggedTabId: draggedTabId,
            proposedInsertionPosition: insertionPosition,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        )
        let legalTargetIndex = resolvedTargetIndex(
            from: fromIndex,
            insertionPosition: legalInsertionPosition,
            totalCount: tabIds.count
        )
        guard legalTargetIndex != fromIndex else { return nil }
        return indicatorForInsertionPosition(legalInsertionPosition, tabIds: tabIds)
    }

    static func targetIndex(
        draggedTabId: UUID,
        targetTabId: UUID?,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>
    ) -> Int? {
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let indicator, let indicatorInsertion = insertionPositionForIndicator(indicator, tabIds: tabIds) {
            insertionPosition = indicatorInsertion
        } else if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge = (indicator?.tabId == targetTabId)
                ? (indicator?.edge ?? preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds))
                : preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        let legalInsertionPosition = legalInsertionPosition(
            draggedTabId: draggedTabId,
            proposedInsertionPosition: insertionPosition,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        )
        return resolvedTargetIndex(from: fromIndex, insertionPosition: legalInsertionPosition, totalCount: tabIds.count)
    }

    struct WorkspaceDropTarget: Equatable {
        let workspaceId: UUID
        let index: Int
        let isPinned: Bool
        let frame: CGRect
    }

    enum WorkspaceDropAction: Equatable {
        case newWorkspace(insertionIndex: Int, indicator: SidebarDropIndicator)
        case existingWorkspace(UUID)
    }

    static func workspaceAction(
        for point: CGPoint,
        targets: [WorkspaceDropTarget],
        workspaceCount: Int? = nil,
        pinnedWorkspaceCount: Int? = nil
    ) -> WorkspaceDropAction? {
        guard !targets.isEmpty else { return nil }
        let orderedTargets = targets.sorted { $0.frame.minY < $1.frame.minY }
        let totalWorkspaceCount = workspaceCount ?? orderedTargets.count
        let totalPinnedWorkspaceCount = pinnedWorkspaceCount ?? orderedTargets.reduce(into: 0) { count, target in
            if target.isPinned {
                count += 1
            }
        }
        if let containingTarget = orderedTargets.first(where: { $0.frame.contains(point) }) {
            return workspaceAction(
                for: point,
                in: containingTarget,
                orderedTargets: orderedTargets,
                workspaceCount: totalWorkspaceCount,
                pinnedWorkspaceCount: totalPinnedWorkspaceCount
            )
        }

        let proposedInsertion: Int
        if let beforeTarget = orderedTargets.first(where: { point.y < $0.frame.minY }) {
            proposedInsertion = beforeTarget.index
        } else {
            proposedInsertion = (orderedTargets.last?.index ?? -1) + 1
        }
        let insertionIndex = legalNewWorkspaceInsertionIndex(
            proposedInsertion,
            workspaceCount: totalWorkspaceCount,
            pinnedWorkspaceCount: totalPinnedWorkspaceCount
        )
        return .newWorkspace(
            insertionIndex: insertionIndex,
            indicator: workspaceIndicator(
                forInsertionIndex: insertionIndex,
                workspaceCount: totalWorkspaceCount,
                orderedTargets: orderedTargets
            )
        )
    }

    private static func workspaceAction(
        for point: CGPoint,
        in target: WorkspaceDropTarget,
        orderedTargets: [WorkspaceDropTarget],
        workspaceCount: Int,
        pinnedWorkspaceCount: Int
    ) -> WorkspaceDropAction? {
        let edgeBand = min(max(target.frame.height * 0.25, 10), target.frame.height / 2)
        if point.y <= target.frame.minY + edgeBand {
            let insertionIndex = legalNewWorkspaceInsertionIndex(
                target.index,
                workspaceCount: workspaceCount,
                pinnedWorkspaceCount: pinnedWorkspaceCount
            )
            return .newWorkspace(
                insertionIndex: insertionIndex,
                indicator: workspaceIndicator(
                    forInsertionIndex: insertionIndex,
                    workspaceCount: workspaceCount,
                    orderedTargets: orderedTargets
                )
            )
        }
        if point.y >= target.frame.maxY - edgeBand {
            let insertionIndex = legalNewWorkspaceInsertionIndex(
                target.index + 1,
                workspaceCount: workspaceCount,
                pinnedWorkspaceCount: pinnedWorkspaceCount
            )
            return .newWorkspace(
                insertionIndex: insertionIndex,
                indicator: workspaceIndicator(
                    forInsertionIndex: insertionIndex,
                    workspaceCount: workspaceCount,
                    orderedTargets: orderedTargets
                )
            )
        }
        return .existingWorkspace(target.workspaceId)
    }

    private static func legalNewWorkspaceInsertionIndex(
        _ proposedInsertion: Int,
        workspaceCount: Int,
        pinnedWorkspaceCount: Int
    ) -> Int {
        let clamped = max(0, min(proposedInsertion, workspaceCount))
        return max(clamped, pinnedWorkspaceCount)
    }

    private static func workspaceIndicator(
        forInsertionIndex insertionIndex: Int,
        workspaceCount: Int,
        orderedTargets: [WorkspaceDropTarget]
    ) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionIndex, workspaceCount))
        if clampedInsertion >= workspaceCount {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        let targetsByIndex = orderedTargets.sorted { $0.index < $1.index }
        if let exactTarget = targetsByIndex.first(where: { $0.index == clampedInsertion }) {
            return SidebarDropIndicator(tabId: exactTarget.workspaceId, edge: .top)
        }
        if let nextTarget = targetsByIndex.first(where: { $0.index > clampedInsertion }) {
            return SidebarDropIndicator(tabId: nextTarget.workspaceId, edge: .top)
        }
        if let previousTarget = targetsByIndex.last(where: { $0.index < clampedInsertion }) {
            return SidebarDropIndicator(tabId: previousTarget.workspaceId, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: nil, edge: .bottom)
    }

    private static func indicatorForInsertionPosition(_ insertionPosition: Int, tabIds: [UUID]) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionPosition, tabIds.count))
        if clampedInsertion >= tabIds.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: tabIds[clampedInsertion], edge: .top)
    }

    private static func insertionPositionForIndicator(_ indicator: SidebarDropIndicator, tabIds: [UUID]) -> Int? {
        if let tabId = indicator.tabId {
            guard let targetTabIndex = tabIds.firstIndex(of: tabId) else { return nil }
            return indicator.edge == .bottom ? targetTabIndex + 1 : targetTabIndex
        }
        return tabIds.count
    }

    private static func preferredEdge(fromIndex: Int, targetTabId: UUID, tabIds: [UUID]) -> SidebarDropEdge {
        guard let targetIndex = tabIds.firstIndex(of: targetTabId) else { return .top }
        return fromIndex < targetIndex ? .bottom : .top
    }

    private static func legalInsertionPosition(
        draggedTabId: UUID,
        proposedInsertionPosition: Int,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>
    ) -> Int {
        let clampedInsertion = max(0, min(proposedInsertionPosition, tabIds.count))
        guard !pinnedTabIds.isEmpty else { return clampedInsertion }

        let pinnedCount = tabIds.reduce(into: 0) { count, tabId in
            if pinnedTabIds.contains(tabId) {
                count += 1
            }
        }
        guard pinnedCount > 0 else { return clampedInsertion }

        if pinnedTabIds.contains(draggedTabId) {
            return min(clampedInsertion, pinnedCount)
        }
        return max(clampedInsertion, pinnedCount)
    }

    static func edgeForPointer(locationY: CGFloat, targetHeight: CGFloat) -> SidebarDropEdge {
        guard targetHeight > 0 else { return .top }
        let clampedY = min(max(locationY, 0), targetHeight)
        return clampedY < (targetHeight / 2) ? .top : .bottom
    }

    private static func resolvedTargetIndex(from sourceIndex: Int, insertionPosition: Int, totalCount: Int) -> Int {
        let clampedInsertion = max(0, min(insertionPosition, totalCount))
        let adjusted = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
        return max(0, min(adjusted, max(0, totalCount - 1)))
    }
}
