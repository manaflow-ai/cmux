public import CoreGraphics
public import Foundation

/// Pure planner for sidebar tab/workspace drag-and-drop. Computes the drop
/// indicator to render, the final insertion index, cross-window insertion
/// landing, and workspace drop-target hit testing, all clamped to the legal
/// pinned/unpinned regions. No UI or AppKit dependencies.
public struct SidebarDropPlanner {
    public init() {}

    public func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        legalInsertionRange: ClosedRange<Int>? = nil,
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil,
        preserveTargetEdge: Bool = false
    ) -> SidebarDropIndicator? {
        indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: pointerY,
            targetHeight: targetHeight,
            preserveTargetEdge: preserveTargetEdge,
            suppressesNoOp: true
        )
    }

    func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        legalInsertionRange: ClosedRange<Int>? = nil,
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil,
        preserveTargetEdge: Bool = false,
        suppressesNoOp: Bool
    ) -> SidebarDropIndicator? {
        guard tabIds.count > 1, let draggedTabId else { return nil }
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        let proposedIndicator: SidebarDropIndicator?
        if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge: SidebarDropEdge
            if let pointerY, let targetHeight {
                edge = edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
            } else {
                edge = preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            }
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
            proposedIndicator = SidebarDropIndicator(tabId: targetTabId, edge: edge)
        } else {
            insertionPosition = tabIds.count
            proposedIndicator = SidebarDropIndicator(tabId: nil, edge: .bottom)
        }

        let legalInsertionPosition = legalInsertionPosition(
            draggedTabId: draggedTabId,
            proposedInsertionPosition: insertionPosition,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange
        )
        if suppressesNoOp {
            let legalTargetIndex = resolvedTargetIndex(
                from: fromIndex,
                insertionPosition: legalInsertionPosition,
                totalCount: tabIds.count
            )
            guard legalTargetIndex != fromIndex else { return nil }
        }
        if preserveTargetEdge, legalInsertionPosition == insertionPosition {
            return proposedIndicator
        }
        return indicatorForInsertionPosition(legalInsertionPosition, tabIds: tabIds)
    }

    public func targetIndex(
        draggedTabId: UUID,
        targetTabId: UUID?,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        legalInsertionRange: ClosedRange<Int>? = nil
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
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange
        )
        return resolvedTargetIndex(from: fromIndex, insertionPosition: legalInsertionPosition, totalCount: tabIds.count)
    }

    /// Converts a target index planned in a scoped row list into a destination row-space index.
    ///
    /// Use this when drag hit-testing sees only a filtered subset of rows, but
    /// the commit coordinator expects indexes in the full backing row space.
    public func remappedTargetIndex(
        scopedTargetIndex: Int,
        draggedTabId: UUID,
        scopedTabIds: [UUID],
        destinationTabIds: [UUID]
    ) -> Int? {
        guard let sourceIndex = destinationTabIds.firstIndex(of: draggedTabId),
              let scopedSourceIndex = scopedTabIds.firstIndex(of: draggedTabId) else {
            return nil
        }
        var finalScopedIds = scopedTabIds
        let dragged = finalScopedIds.remove(at: scopedSourceIndex)
        finalScopedIds.insert(dragged, at: max(0, min(scopedTargetIndex, finalScopedIds.count)))
        guard let finalScopedIndex = finalScopedIds.firstIndex(of: draggedTabId) else { return nil }
        let insertionPosition: Int
        if finalScopedIndex + 1 < finalScopedIds.count,
           let nextIndex = destinationTabIds.firstIndex(of: finalScopedIds[finalScopedIndex + 1]) {
            insertionPosition = nextIndex
        } else if finalScopedIndex > 0,
                  let previousIndex = destinationTabIds.firstIndex(of: finalScopedIds[finalScopedIndex - 1]) {
            insertionPosition = previousIndex + 1
        } else {
            insertionPosition = sourceIndex
        }
        return resolvedTargetIndex(
            from: sourceIndex,
            insertionPosition: insertionPosition,
            totalCount: destinationTabIds.count
        )
    }

    /// Where a workspace dragged in from *another window* should land in this
    /// window's sidebar, plus the indicator to render while it hovers.
    ///
    /// Unlike ``indicator(draggedTabId:targetTabId:tabIds:pinnedTabIds:pointerY:targetHeight:)``
    /// and ``targetIndex(draggedTabId:targetTabId:indicator:tabIds:pinnedTabIds:)``,
    /// the dragged workspace is **not** a member of `tabIds` — it currently
    /// lives in a different window — so there is no source index to remove and
    /// the returned index is a plain insertion position in `0...tabIds.count`.
    ///
    /// - Parameters:
    ///   - targetTabId: The hovered row's workspace id, or `nil` for the
    ///     end-of-list / empty area (append).
    ///   - draggedIsPinned: Whether the incoming workspace is pinned, so it is
    ///     clamped into the legal pinned/unpinned region.
    ///   - indicator: A previously computed indicator (used at drop time to
    ///     recover the exact insertion the user saw); pass `nil` to derive the
    ///     position from `targetTabId` and the pointer.
    ///   - tabIds: This window's workspace ids, in sidebar order.
    ///   - pinnedTabIds: The subset of `tabIds` that are pinned.
    ///   - pointerY: Pointer y within the hovered row, used to pick the edge.
    ///   - targetHeight: The hovered row's height, paired with `pointerY`.
    /// - Returns: The clamped insertion index and the indicator to render.
    public func crossWindowInsertion(
        targetTabId: UUID?,
        draggedIsPinned: Bool,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil
    ) -> (insertionIndex: Int, indicator: SidebarDropIndicator) {
        let proposed: Int
        if let indicator, let indicatorInsertion = insertionPositionForIndicator(indicator, tabIds: tabIds) {
            proposed = indicatorInsertion
        } else if let targetTabId, let targetTabIndex = tabIds.firstIndex(of: targetTabId) {
            let edge: SidebarDropEdge
            if let pointerY, let targetHeight {
                edge = edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
            } else {
                edge = .top
            }
            proposed = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            proposed = tabIds.count
        }

        let legalInsertion = legalCrossWindowInsertionPosition(
            proposedInsertionPosition: proposed,
            draggedIsPinned: draggedIsPinned,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        )
        return (legalInsertion, indicatorForInsertionPosition(legalInsertion, tabIds: tabIds))
    }

    /// Clamp a cross-window insertion so a pinned workspace lands inside the
    /// leading pinned block and an unpinned one lands after it.
    ///
    /// The clamp applies even when `pinnedCount` is zero: a pinned workspace
    /// dragged into a window with no existing pins must still land at the front
    /// (index `0`), not wherever the pointer happens to be, otherwise it would
    /// sit below unpinned rows and break the leading-pinned-segment invariant.
    private func legalCrossWindowInsertionPosition(
        proposedInsertionPosition: Int,
        draggedIsPinned: Bool,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>
    ) -> Int {
        let clampedInsertion = max(0, min(proposedInsertionPosition, tabIds.count))
        let pinnedCount = tabIds.reduce(into: 0) { count, tabId in
            if pinnedTabIds.contains(tabId) {
                count += 1
            }
        }
        return draggedIsPinned ? min(clampedInsertion, pinnedCount) : max(clampedInsertion, pinnedCount)
    }

    /// A sidebar workspace row that can receive a workspace drop.
    public struct WorkspaceDropTarget: Equatable {
        /// The workspace represented by this sidebar row.
        public let workspaceId: UUID

        /// Whether the workspace belongs to the leading pinned section.
        public let isPinned: Bool

        /// The row frame in the coordinate space used for drop hit testing.
        public let frame: CGRect

        /// Creates a workspace drop target from a row snapshot.
        ///
        /// - Parameters:
        ///   - workspaceId: The workspace represented by the row.
        ///   - isPinned: Whether the row is in the pinned workspace section.
        ///   - frame: The row frame in drop-overlay coordinates.
        public init(workspaceId: UUID, isPinned: Bool, frame: CGRect) {
            self.workspaceId = workspaceId
            self.isPinned = isPinned
            self.frame = frame
        }
    }

    /// Returns whether sidebar rows should publish frame anchors for workspace drop targeting.
    public func shouldCollectWorkspaceDropTargets(
        draggedTabId: UUID?,
        isBonsplitWorkspaceDropActive: Bool = false
    ) -> Bool {
        draggedTabId != nil || isBonsplitWorkspaceDropActive
    }

    /// The action to perform for a Bonsplit tab dropped over sidebar workspaces.
    public enum WorkspaceDropAction: Equatable {
        /// Create a new workspace at the insertion index and render the indicator.
        case newWorkspace(insertionIndex: Int, indicator: SidebarDropIndicator)

        /// Move the dropped tab into the existing workspace.
        case existingWorkspace(UUID)
    }

    /// Returns the workspace drop action for a pointer and unordered targets.
    ///
    /// This overload sorts the targets before hit testing. Prefer
    /// ``workspaceAction(for:targets:)`` with ``OrderedWorkspaceDropTargets``
    /// when the same target collection is reused across many pointer updates.
    ///
    /// - Parameters:
    ///   - point: The pointer location in the target coordinate space.
    ///   - targets: The current workspace drop targets.
    /// - Returns: The existing-workspace or new-workspace action to perform.
    public func workspaceAction(
        for point: CGPoint,
        targets: [WorkspaceDropTarget]
    ) -> WorkspaceDropAction? {
        workspaceAction(for: point, targets: OrderedWorkspaceDropTargets(targets))
    }

    /// Returns the workspace drop action for a pointer using preordered targets.
    ///
    /// Use this overload when the same target collection is hit-tested across
    /// many pointer updates, such as an AppKit drag session, so target sorting
    /// happens once when row frames change rather than on every drag tick.
    public func workspaceAction(
        for point: CGPoint,
        targets orderedTargetCollection: OrderedWorkspaceDropTargets
    ) -> WorkspaceDropAction? {
        let orderedTargets = orderedTargetCollection.targets
        guard !orderedTargets.isEmpty else { return nil }
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

    private func workspaceAction(
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

    private func legalNewWorkspaceInsertionIndex(
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

    private func workspaceIndicator(
        forInsertionIndex insertionIndex: Int,
        orderedTargets: [WorkspaceDropTarget]
    ) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionIndex, orderedTargets.count))
        if clampedInsertion >= orderedTargets.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: orderedTargets[clampedInsertion].workspaceId, edge: .top)
    }

    private func indicatorForInsertionPosition(_ insertionPosition: Int, tabIds: [UUID]) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionPosition, tabIds.count))
        if clampedInsertion >= tabIds.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: tabIds[clampedInsertion], edge: .top)
    }

    private func insertionPositionForIndicator(_ indicator: SidebarDropIndicator, tabIds: [UUID]) -> Int? {
        if let tabId = indicator.tabId {
            guard let targetTabIndex = tabIds.firstIndex(of: tabId) else { return nil }
            return indicator.edge == .bottom ? targetTabIndex + 1 : targetTabIndex
        }
        return tabIds.count
    }

    private func preferredEdge(fromIndex: Int, targetTabId: UUID, tabIds: [UUID]) -> SidebarDropEdge {
        guard let targetIndex = tabIds.firstIndex(of: targetTabId) else { return .top }
        return fromIndex < targetIndex ? .bottom : .top
    }

    private func legalInsertionPosition(
        draggedTabId: UUID,
        proposedInsertionPosition: Int,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        legalInsertionRange: ClosedRange<Int>?
    ) -> Int {
        var clampedInsertion = max(0, min(proposedInsertionPosition, tabIds.count))

        if !pinnedTabIds.isEmpty {
            let pinnedCount = tabIds.reduce(into: 0) { count, tabId in
                if pinnedTabIds.contains(tabId) {
                    count += 1
                }
            }
            if pinnedCount > 0 {
                if pinnedTabIds.contains(draggedTabId) {
                    clampedInsertion = min(clampedInsertion, pinnedCount)
                } else {
                    clampedInsertion = max(clampedInsertion, pinnedCount)
                }
            }
        }

        if let legalInsertionRange {
            return min(max(clampedInsertion, legalInsertionRange.lowerBound), legalInsertionRange.upperBound)
        }
        return clampedInsertion
    }

    public func edgeForPointer(locationY: CGFloat, targetHeight: CGFloat) -> SidebarDropEdge {
        guard targetHeight > 0 else { return .top }
        let clampedY = min(max(locationY, 0), targetHeight)
        return clampedY < (targetHeight / 2) ? .top : .bottom
    }

    private func resolvedTargetIndex(from sourceIndex: Int, insertionPosition: Int, totalCount: Int) -> Int {
        let clampedInsertion = max(0, min(insertionPosition, totalCount))
        let adjusted = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
        return max(0, min(adjusted, max(0, totalCount - 1)))
    }
}
