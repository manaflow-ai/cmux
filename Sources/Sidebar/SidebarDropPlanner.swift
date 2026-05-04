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
        let isPinned: Bool
        let frame: CGRect
    }

    enum WorkspaceDropAction: Equatable {
        case newWorkspace(insertionIndex: Int, indicator: SidebarDropIndicator)
        case existingWorkspace(UUID)
    }

    static func workspaceAction(
        for point: CGPoint,
        targets: [WorkspaceDropTarget]
    ) -> WorkspaceDropAction? {
        guard !targets.isEmpty else { return nil }
        let orderedTargets = targets.sorted { $0.frame.minY < $1.frame.minY }
        if let containingTarget = orderedTargets.first(where: { $0.frame.contains(point) }) {
            return workspaceAction(for: point, in: containingTarget, orderedTargets: orderedTargets)
        }

        let proposedInsertion: Int
        if let beforeTarget = orderedTargets.first(where: { point.y < $0.frame.minY }) {
            proposedInsertion = orderedTargets.firstIndex(of: beforeTarget) ?? 0
        } else {
            proposedInsertion = orderedTargets.count
        }
        let insertionIndex = legalNewWorkspaceInsertionIndex(
            proposedInsertion,
            orderedTargets: orderedTargets
        )
        return .newWorkspace(
            insertionIndex: insertionIndex,
            indicator: workspaceIndicator(forInsertionIndex: insertionIndex, orderedTargets: orderedTargets)
        )
    }

    private static func workspaceAction(
        for point: CGPoint,
        in target: WorkspaceDropTarget,
        orderedTargets: [WorkspaceDropTarget]
    ) -> WorkspaceDropAction? {
        guard let targetIndex = orderedTargets.firstIndex(of: target) else { return nil }
        let edgeBand = min(max(target.frame.height * 0.25, 10), target.frame.height / 2)
        if point.y <= target.frame.minY + edgeBand {
            let insertionIndex = legalNewWorkspaceInsertionIndex(targetIndex, orderedTargets: orderedTargets)
            return .newWorkspace(
                insertionIndex: insertionIndex,
                indicator: workspaceIndicator(forInsertionIndex: insertionIndex, orderedTargets: orderedTargets)
            )
        }
        if point.y >= target.frame.maxY - edgeBand {
            let insertionIndex = legalNewWorkspaceInsertionIndex(targetIndex + 1, orderedTargets: orderedTargets)
            return .newWorkspace(
                insertionIndex: insertionIndex,
                indicator: workspaceIndicator(forInsertionIndex: insertionIndex, orderedTargets: orderedTargets)
            )
        }
        return .existingWorkspace(target.workspaceId)
    }

    private static func legalNewWorkspaceInsertionIndex(
        _ proposedInsertion: Int,
        orderedTargets: [WorkspaceDropTarget]
    ) -> Int {
        let clamped = max(0, min(proposedInsertion, orderedTargets.count))
        let pinnedCount = orderedTargets.reduce(into: 0) { count, target in
            if target.isPinned {
                count += 1
            }
        }
        return max(clamped, pinnedCount)
    }

    private static func workspaceIndicator(
        forInsertionIndex insertionIndex: Int,
        orderedTargets: [WorkspaceDropTarget]
    ) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionIndex, orderedTargets.count))
        if clampedInsertion >= orderedTargets.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: orderedTargets[clampedInsertion].workspaceId, edge: .top)
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
