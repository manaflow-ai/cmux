import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation

/// Owns native table drag/drop without putting live workspace scans on the
/// pointer-update path.
///
/// A native workspace drag snapshots the destination rows once when AppKit
/// starts the session. Validation then resolves the proposed row through
/// constant-time dictionaries. The full reorder resolver runs only after
/// AppKit accepts the drop.
@MainActor
final class SidebarAppKitDragCoordinator {
    struct StateAccess {
        var selectedWorkspaceIds: () -> Set<UUID>
        var setSelectedWorkspaceIds: (Set<UUID>) -> Void
        var lastSelectionIndex: () -> Int?
        var setLastSelectionIndex: (Int?) -> Void
        var selectTabsPage: () -> Void
    }

    private struct MovingWorkspace {
        let id: UUID
        let isPinned: Bool
    }

    @MainActor
    private final class OriginMetadata {
        let draggedWorkspaceId: UUID
        let draggedIsPinned: Bool
        let isGroupAnchor: Bool
        let movingWorkspaces: [MovingWorkspace]

        init(
            draggedWorkspaceId: UUID,
            draggedIsPinned: Bool,
            isGroupAnchor: Bool,
            movingWorkspaces: [MovingWorkspace]
        ) {
            self.draggedWorkspaceId = draggedWorkspaceId
            self.draggedIsPinned = draggedIsPinned
            self.isGroupAnchor = isGroupAnchor
            self.movingWorkspaces = movingWorkspaces
        }
    }

    /// Immutable model and synthetic row geometry used by one drag session.
    @MainActor
    private struct SessionSnapshot {
        let workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot]
        let workspaceById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot]
        let workspaceIds: [UUID]
        let groups: [SidebarWorkspaceReorderGroupSnapshot]
        let groupAnchorIds: Set<UUID>
        let targets: [SidebarWorkspaceReorderDropTarget]
        let targetByItemId: [SidebarWorkspaceRenderItemID: SidebarWorkspaceReorderDropTarget]
        let targetIndexByItemId: [SidebarWorkspaceRenderItemID: Int]
        let workspaceIdByItemId: [SidebarWorkspaceRenderItemID: UUID]
        let visiblePinnedTargetCount: Int

        init(
            tabManager: TabManager,
            renderItems: [SidebarWorkspaceRenderItem]
        ) {
            let workspaceSnapshots = tabManager.tabs.map {
                SidebarWorkspaceReorderWorkspaceSnapshot(
                    id: $0.id,
                    isPinned: $0.isPinned,
                    groupId: $0.groupId
                )
            }
            let workspaceById = Dictionary(
                uniqueKeysWithValues: workspaceSnapshots.map { ($0.id, $0) }
            )
            let groupSnapshots = tabManager.workspaceGroups.map {
                SidebarWorkspaceReorderGroupSnapshot(
                    id: $0.id,
                    anchorWorkspaceId: $0.anchorWorkspaceId,
                    isPinned: $0.isPinned
                )
            }
            let groupById = Dictionary(
                uniqueKeysWithValues: groupSnapshots.map { ($0.id, $0) }
            )

            var targets: [SidebarWorkspaceReorderDropTarget] = []
            targets.reserveCapacity(renderItems.count)
            var targetByItemId: [
                SidebarWorkspaceRenderItemID: SidebarWorkspaceReorderDropTarget
            ] = [:]
            targetByItemId.reserveCapacity(renderItems.count)
            var targetIndexByItemId: [SidebarWorkspaceRenderItemID: Int] = [:]
            targetIndexByItemId.reserveCapacity(renderItems.count)
            var workspaceIdByItemId: [SidebarWorkspaceRenderItemID: UUID] = [:]
            workspaceIdByItemId.reserveCapacity(renderItems.count)
            var visiblePinnedTargetCount = 0

            for (row, item) in renderItems.enumerated() {
                let workspaceId = item.rowWorkspaceId
                let groupId: UUID?
                let isGroupHeader: Bool
                let isPinned: Bool
                switch item {
                case .groupHeader(let itemGroupId, _):
                    groupId = itemGroupId
                    isGroupHeader = true
                    isPinned = groupById[itemGroupId]?.isPinned ?? false
                case .workspace:
                    groupId = workspaceById[workspaceId]?.groupId
                    isGroupHeader = false
                    isPinned = workspaceById[workspaceId]?.isPinned ?? false
                }

                let target = SidebarWorkspaceReorderDropTarget(
                    workspaceId: workspaceId,
                    groupId: groupId,
                    isGroupHeader: isGroupHeader,
                    frame: CGRect(x: 0, y: CGFloat(row), width: 2, height: 1)
                )
                targets.append(target)
                targetByItemId[item.id] = target
                targetIndexByItemId[item.id] = row
                workspaceIdByItemId[item.id] = workspaceId
                if isPinned {
                    visiblePinnedTargetCount += 1
                }
            }

            self.workspaces = workspaceSnapshots
            self.workspaceById = workspaceById
            workspaceIds = workspaceSnapshots.map(\.id)
            groups = groupSnapshots
            groupAnchorIds = Set(groupSnapshots.map(\.anchorWorkspaceId))
            self.targets = targets
            self.targetByItemId = targetByItemId
            self.targetIndexByItemId = targetIndexByItemId
            self.workspaceIdByItemId = workspaceIdByItemId
            self.visiblePinnedTargetCount = visiblePinnedTargetCount
        }
    }

    private struct ActiveSession {
        let draggedWorkspaceId: UUID
        let snapshot: SessionSnapshot
        let selectionBeforeReorder: Set<UUID>
        let preferredAnchorWorkspaceId: UUID?
    }

    private enum ProposalKind {
        case workspace(UUID)
        case bonsplit
    }

    private struct ProposedDrop {
        let kind: ProposalKind
        let itemId: SidebarWorkspaceRenderItemID?
        let row: Int
        let operation: NSTableView.DropOperation
    }

    private static let workspacePasteboardType = NSPasteboard.PasteboardType(
        SidebarTabDragPayload.typeIdentifier
    )
    private static let bonsplitPasteboardType = NSPasteboard.PasteboardType(
        BonsplitTabDragPayload.typeIdentifier
    )

    /// The process has at most one sidebar workspace drag at a time. This
    /// augments the shared id registry with immutable source-window metadata so
    /// destination validation does not search every window on each pointer tick.
    private static var originMetadata: OriginMetadata?

    private let tabManager: TabManager
    private let projectionSource: SidebarAppKitProjectionSource
    private let windowId: UUID
    private let workspaceDragRegistry: any SidebarWorkspaceDragRegistering
    private var state: StateAccess
    private var activeSession: ActiveSession?
    private var proposedDrop: ProposedDrop?

    /// Lightweight counters allow scale tests to prove that pointer movement
    /// neither rebuilds the session snapshot nor invokes the reorder resolver.
    private(set) var sessionSnapshotBuildCount = 0
    private(set) var reorderResolverInvocationCount = 0

    init(
        tabManager: TabManager,
        projectionSource: SidebarAppKitProjectionSource,
        windowId: UUID,
        workspaceDragRegistry: any SidebarWorkspaceDragRegistering,
        state: StateAccess
    ) {
        self.tabManager = tabManager
        self.projectionSource = projectionSource
        self.windowId = windowId
        self.workspaceDragRegistry = workspaceDragRegistry
        self.state = state
    }

    func updateStateAccess(_ state: StateAccess) {
        self.state = state
    }

    /// Ends a native drag owned by this coordinator. Runtime teardown can call
    /// this even when no drag is active without disturbing another window's
    /// source session.
    func cancelActiveDrag() {
        guard let draggedWorkspaceId = activeSession?.draggedWorkspaceId else {
            proposedDrop = nil
            return
        }
        finishWorkspaceDrag(draggedWorkspaceId)
    }

    func dragHandlers() -> SidebarAppKitConfiguration.DragHandlers {
        SidebarAppKitConfiguration.DragHandlers(
            registeredTypes: [
                Self.workspacePasteboardType,
                Self.bonsplitPasteboardType,
            ],
            localSourceOperationMask: .move,
            externalSourceOperationMask: [],
            pasteboardWriter: { [weak self] item in
                self?.pasteboardWriter(for: item)
            },
            validateDrop: { [weak self] info, item, row, operation in
                self?.validateDrop(
                    info,
                    proposedItem: item,
                    row: row,
                    operation: operation
                ) ?? []
            },
            acceptDrop: { [weak self] info, item, row, operation in
                self?.acceptDrop(
                    info,
                    proposedItem: item,
                    row: row,
                    operation: operation
                ) ?? false
            },
            dragSessionBegan: { [weak self] session, itemIds in
                self?.dragSessionBegan(session, itemIds: itemIds)
            },
            dragSessionEnded: { [weak self] session, point, operation in
                self?.dragSessionEnded(session, point: point, operation: operation)
            },
            updateDraggingItems: { [weak self] info in
                self?.updateDraggingItems(info)
            }
        )
    }

    private func pasteboardWriter(
        for item: SidebarWorkspaceRenderItem
    ) -> (any NSPasteboardWriting)? {
        let payload = "\(SidebarTabDragPayload.prefix)\(item.rowWorkspaceId.uuidString)"
        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setData(
            Data(payload.utf8),
            forType: Self.workspacePasteboardType
        ) else {
            return nil
        }
        return pasteboardItem
    }

    private func dragSessionBegan(
        _ session: NSDraggingSession,
        itemIds: [SidebarWorkspaceRenderItemID]
    ) {
        _ = session
        let snapshot = makeSessionSnapshot()
        var draggedWorkspaceId: UUID?
        for itemId in itemIds {
            if let workspaceId = snapshot.workspaceIdByItemId[itemId] {
                draggedWorkspaceId = workspaceId
                break
            }
        }
        guard let draggedWorkspaceId,
              let draggedWorkspace = snapshot.workspaceById[draggedWorkspaceId] else {
            return
        }

        let selectionBeforeReorder = state.selectedWorkspaceIds()
        let preferredAnchorWorkspaceId = SidebarWorkspaceSelectionSyncPolicy()
            .anchorWorkspaceId(
                existingAnchorIndex: state.lastSelectionIndex(),
                liveWorkspaceIds: snapshot.workspaceIds
            )
        activeSession = ActiveSession(
            draggedWorkspaceId: draggedWorkspaceId,
            snapshot: snapshot,
            selectionBeforeReorder: selectionBeforeReorder,
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId
        )
        Self.originMetadata = makeOriginMetadata(
            draggedWorkspaceId: draggedWorkspaceId,
            draggedIsPinned: draggedWorkspace.isPinned,
            groupAnchorIds: snapshot.groupAnchorIds,
            workspaces: snapshot.workspaces,
            selectedWorkspaceIds: selectionBeforeReorder
        )
        workspaceDragRegistry.begin(workspaceId: draggedWorkspaceId)
        SidebarDragLifecycleNotification().postStateDidChange(
            tabId: draggedWorkspaceId,
            reason: "appkit_drag_begin"
        )
    }

    private func dragSessionEnded(
        _ session: NSDraggingSession,
        point: NSPoint,
        operation: NSDragOperation
    ) {
        _ = session
        _ = point
        _ = operation
        guard let draggedWorkspaceId = activeSession?.draggedWorkspaceId else {
            proposedDrop = nil
            return
        }
        finishWorkspaceDrag(draggedWorkspaceId)
    }

    private func validateDrop(
        _ info: NSDraggingInfo,
        proposedItem: SidebarWorkspaceRenderItem?,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if let proposal = workspaceProposal(
            info,
            proposedItem: proposedItem,
            row: row,
            operation: operation
        ) {
            proposedDrop = proposal
            return .move
        }
        if let proposal = bonsplitProposal(
            info,
            proposedItem: proposedItem,
            row: row,
            operation: operation
        ) {
            proposedDrop = proposal
            return .move
        }
        proposedDrop = nil
        return []
    }

    /// NSTableView already carries the proposed row and operation through
    /// `validateDrop`. Keep this callback constant-time and let AppKit update
    /// its native insertion marker from the cached proposal.
    private func updateDraggingItems(_ info: NSDraggingInfo) {
        _ = info.draggingSequenceNumber
        _ = proposedDrop
    }

    private func acceptDrop(
        _ info: NSDraggingInfo,
        proposedItem: SidebarWorkspaceRenderItem?,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> Bool {
        if let proposal = workspaceProposal(
            info,
            proposedItem: proposedItem,
            row: row,
            operation: operation
        ) {
            proposedDrop = proposal
            return acceptWorkspaceDrop(proposal)
        }
        if let proposal = bonsplitProposal(
            info,
            proposedItem: proposedItem,
            row: row,
            operation: operation
        ) {
            proposedDrop = proposal
            return acceptBonsplitDrop(info, proposal: proposal)
        }
        proposedDrop = nil
        return false
    }

    private func workspaceProposal(
        _ info: NSDraggingInfo,
        proposedItem: SidebarWorkspaceRenderItem?,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> ProposedDrop? {
        guard info.draggingPasteboard.types?.contains(Self.workspacePasteboardType) == true,
              let draggedWorkspaceId = activeSession?.draggedWorkspaceId
                ?? workspaceDragRegistry.currentWorkspaceId else {
            return nil
        }

        let isLocalWorkspace = projectionSource.workspaceById[draggedWorkspaceId] != nil
        if !isLocalWorkspace,
           let origin = Self.originMetadata,
           origin.draggedWorkspaceId == draggedWorkspaceId,
           origin.isGroupAnchor {
            return nil
        }

        let sessionSnapshot = activeSession?.draggedWorkspaceId == draggedWorkspaceId
            ? activeSession?.snapshot
            : nil
        guard isValidProposedTarget(
            proposedItem,
            row: row,
            operation: operation,
            sessionSnapshot: sessionSnapshot
        ) else {
            return nil
        }
        return ProposedDrop(
            kind: .workspace(draggedWorkspaceId),
            itemId: proposedItem?.id,
            row: row,
            operation: operation
        )
    }

    private func bonsplitProposal(
        _ info: NSDraggingInfo,
        proposedItem: SidebarWorkspaceRenderItem?,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> ProposedDrop? {
        guard BonsplitTabDragPayload.canRouteWorkspaceDrop(
            pasteboardTypes: info.draggingPasteboard.types
        ),
        isValidProposedTarget(
            proposedItem,
            row: row,
            operation: operation,
            sessionSnapshot: nil
        ) else {
            return nil
        }
        return ProposedDrop(
            kind: .bonsplit,
            itemId: proposedItem?.id,
            row: row,
            operation: operation
        )
    }

    /// This is called by validation, so it must remain independent of the
    /// total workspace count.
    private func isValidProposedTarget(
        _ item: SidebarWorkspaceRenderItem?,
        row: Int,
        operation: NSTableView.DropOperation,
        sessionSnapshot: SessionSnapshot?
    ) -> Bool {
        guard row >= 0 else { return false }
        switch operation {
        case .on:
            guard let item else { return false }
            if let sessionSnapshot {
                return sessionSnapshot.targetByItemId[item.id] != nil
            }
            return projectionSource.workspaceById[item.rowWorkspaceId] != nil
        case .above:
            if let item {
                if let sessionSnapshot {
                    return sessionSnapshot.targetByItemId[item.id] != nil
                }
                return projectionSource.workspaceById[item.rowWorkspaceId] != nil
            }
            let itemCount = sessionSnapshot?.targets.count
                ?? projectionSource.renderItems.count
            return row <= itemCount
        @unknown default:
            return false
        }
    }

    private func acceptWorkspaceDrop(_ proposal: ProposedDrop) -> Bool {
        guard case .workspace(let draggedWorkspaceId) = proposal.kind else {
            return false
        }
        defer { finishWorkspaceDrag(draggedWorkspaceId) }

        let snapshot: SessionSnapshot
        if let activeSession,
           activeSession.draggedWorkspaceId == draggedWorkspaceId {
            snapshot = activeSession.snapshot
        } else {
            snapshot = makeSessionSnapshot()
        }
        guard let point = resolverPoint(for: proposal, snapshot: snapshot) else {
            return false
        }

        let isCrossWindow = snapshot.workspaceById[draggedWorkspaceId] == nil
        let origin = matchingOriginMetadata(for: draggedWorkspaceId)
            ?? (isCrossWindow ? resolveOriginMetadata(for: draggedWorkspaceId) : nil)
        if isCrossWindow, origin?.isGroupAnchor != false {
            return false
        }
        let foreignDraggedIsPinned = isCrossWindow ? origin?.draggedIsPinned : nil
        if isCrossWindow, foreignDraggedIsPinned == nil {
            return false
        }

        reorderResolverInvocationCount += 1
        guard let plan = SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedWorkspaceId,
                foreignDraggedIsPinned: foreignDraggedIsPinned,
                workspaces: snapshot.workspaces,
                groups: snapshot.groups,
                targets: snapshot.targets
            )
        ) else {
            return false
        }

        switch plan.action {
        case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId):
            return acceptSameWindowReorder(
                plan: plan,
                targetIndex: targetIndex,
                usesTopLevelRows: usesTopLevelRows,
                explicitGroupId: explicitGroupId
            )
        case .crossWindow(_, let proposedInsertionIndex):
            guard let origin else { return false }
            return acceptCrossWindowMove(
                plan: plan,
                proposedInsertionIndex: proposedInsertionIndex,
                origin: origin
            )
        }
    }

    private func resolverPoint(
        for proposal: ProposedDrop,
        snapshot: SessionSnapshot
    ) -> CGPoint? {
        if let itemId = proposal.itemId {
            guard let target = snapshot.targetByItemId[itemId] else { return nil }
            switch proposal.operation {
            case .above:
                return CGPoint(x: target.frame.minX + 0.5, y: target.frame.minY)
            case .on:
                return CGPoint(x: target.frame.maxX - 0.5, y: target.frame.midY)
            @unknown default:
                return nil
            }
        }
        guard proposal.operation == .above,
              proposal.row <= snapshot.targets.count else {
            return nil
        }
        return CGPoint(x: 0.5, y: CGFloat(snapshot.targets.count) + 1)
    }

    private func acceptSameWindowReorder(
        plan: SidebarWorkspaceReorderDropPlan,
        targetIndex: Int,
        usesTopLevelRows: Bool,
        explicitGroupId: UUID?
    ) -> Bool {
        let selectionBeforeReorder: Set<UUID>
        let preferredAnchorWorkspaceId: UUID?
        if let activeSession,
           activeSession.draggedWorkspaceId == plan.draggedWorkspaceId {
            selectionBeforeReorder = activeSession.selectionBeforeReorder
            preferredAnchorWorkspaceId = activeSession.preferredAnchorWorkspaceId
        } else {
            let liveWorkspaceIds = tabManager.tabs.map(\.id)
            selectionBeforeReorder = state.selectedWorkspaceIds()
            preferredAnchorWorkspaceId = SidebarWorkspaceSelectionSyncPolicy()
                .anchorWorkspaceId(
                    existingAnchorIndex: state.lastSelectionIndex(),
                    liveWorkspaceIds: liveWorkspaceIds
                )
        }

        let didReorder = tabManager.reorderSidebarWorkspace(
            tabId: plan.draggedWorkspaceId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        syncSelectionAfterReorder(
            preserving: selectionBeforeReorder,
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId
        )
        return didReorder
    }

    private func acceptCrossWindowMove(
        plan: SidebarWorkspaceReorderDropPlan,
        proposedInsertionIndex: Int,
        origin: OriginMetadata
    ) -> Bool {
        guard !origin.isGroupAnchor,
              !origin.movingWorkspaces.isEmpty,
              let app = AppDelegate.shared else {
            return false
        }

        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierWorkspaces = origin.movingWorkspaces.filter {
                $0.isPinned == isPinnedTier
            }
            guard !tierWorkspaces.isEmpty else { continue }

            let topLevelIds = crossWindowTopLevelWorkspaceIds()
            let slot = clampedCrossWindowTopLevelSlot(
                proposedInsertionIndex,
                draggedIsPinned: isPinnedTier,
                topLevelIds: topLevelIds,
                pinnedTopLevelIds: crossWindowTopLevelPinnedWorkspaceIds()
            )
            let base = crossWindowRawInsertIndex(
                forTopLevelSlot: slot,
                topLevelIds: topLevelIds
            )
            var tierOffset = 0
            for workspace in tierWorkspaces {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspace.id,
                    windowId: windowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspace.id)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return false }
        let focusId = movedIds.contains(plan.draggedWorkspaceId)
            ? plan.draggedWorkspaceId
            : (movedIds.last ?? plan.draggedWorkspaceId)
        _ = app.moveWorkspaceToWindow(
            workspaceId: focusId,
            windowId: windowId,
            focus: true
        )
        applySelection(Set(movedIds), preferredWorkspaceId: focusId)
        return true
    }

    private func acceptBonsplitDrop(
        _ info: NSDraggingInfo,
        proposal: ProposedDrop
    ) -> Bool {
        guard case .bonsplit = proposal.kind,
              let transfer = BonsplitTabDragPayload.transfer(
                from: info.draggingPasteboard
              ),
              let app = AppDelegate.shared else {
            return false
        }
        let snapshot = makeSessionSnapshot()

        switch proposal.operation {
        case .on:
            guard let itemId = proposal.itemId,
                  let targetWorkspaceId = snapshot.workspaceIdByItemId[itemId] else {
                return false
            }
            let moved: Bool
            if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
               source.workspaceId == targetWorkspaceId {
                moved = true
            } else {
                moved = app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: targetWorkspaceId,
                    focus: true,
                    focusWindow: true
                )
            }
            guard moved else { return false }
            applySelection(
                [targetWorkspaceId],
                preferredWorkspaceId: targetWorkspaceId
            )
            return true

        case .above:
            let proposedInsertion: Int
            if let itemId = proposal.itemId {
                guard let index = snapshot.targetIndexByItemId[itemId] else {
                    return false
                }
                proposedInsertion = index
            } else {
                proposedInsertion = snapshot.targets.count
            }
            let insertionIndex = max(
                proposedInsertion,
                snapshot.visiblePinnedTargetCount
            )
            guard let result = app.moveBonsplitTabToNewWorkspace(
                tabId: transfer.tab.id,
                destinationManager: tabManager,
                focus: true,
                focusWindow: true,
                insertionIndexOverride: insertionIndex
            ) else {
                return false
            }
            applySelection(
                [result.destinationWorkspaceId],
                preferredWorkspaceId: result.destinationWorkspaceId
            )
            return true

        @unknown default:
            return false
        }
    }

    private func makeSessionSnapshot() -> SessionSnapshot {
        sessionSnapshotBuildCount += 1
        return SessionSnapshot(
            tabManager: tabManager,
            renderItems: projectionSource.renderItems
        )
    }

    private func makeOriginMetadata(
        draggedWorkspaceId: UUID,
        draggedIsPinned: Bool,
        groupAnchorIds: Set<UUID>,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        selectedWorkspaceIds: Set<UUID>
    ) -> OriginMetadata {
        let movesSelection = selectedWorkspaceIds.contains(draggedWorkspaceId)
            && selectedWorkspaceIds.count > 1
        var movingWorkspaces: [MovingWorkspace] = []
        movingWorkspaces.reserveCapacity(
            movesSelection ? selectedWorkspaceIds.count : 1
        )
        for workspace in workspaces {
            let isCandidate = movesSelection
                ? selectedWorkspaceIds.contains(workspace.id)
                : workspace.id == draggedWorkspaceId
            if isCandidate, !groupAnchorIds.contains(workspace.id) {
                movingWorkspaces.append(MovingWorkspace(
                    id: workspace.id,
                    isPinned: workspace.isPinned
                ))
            }
        }
        return OriginMetadata(
            draggedWorkspaceId: draggedWorkspaceId,
            draggedIsPinned: draggedIsPinned,
            isGroupAnchor: groupAnchorIds.contains(draggedWorkspaceId),
            movingWorkspaces: movingWorkspaces
        )
    }

    private func matchingOriginMetadata(
        for draggedWorkspaceId: UUID
    ) -> OriginMetadata? {
        guard let origin = Self.originMetadata,
              origin.draggedWorkspaceId == draggedWorkspaceId else {
            return nil
        }
        return origin
    }

    /// Legacy SwiftUI workspace drags provide only the shared id. Resolve the
    /// richer source metadata once after drop acceptance, never during hover.
    private func resolveOriginMetadata(
        for draggedWorkspaceId: UUID
    ) -> OriginMetadata? {
        guard let sourceManager = AppDelegate.shared?.tabManagerFor(
            tabId: draggedWorkspaceId
        ),
        let draggedWorkspace = sourceManager.tabs.first(where: {
            $0.id == draggedWorkspaceId
        }) else {
            return nil
        }

        let groupAnchorIds = Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        let selectedWorkspaceIds = sourceManager.sidebarSelectedWorkspaceIds
        let movesSelection = selectedWorkspaceIds.contains(draggedWorkspaceId)
            && selectedWorkspaceIds.count > 1
        var movingWorkspaces: [MovingWorkspace] = []
        movingWorkspaces.reserveCapacity(
            movesSelection ? selectedWorkspaceIds.count : 1
        )
        for workspace in sourceManager.tabs {
            let isCandidate = movesSelection
                ? selectedWorkspaceIds.contains(workspace.id)
                : workspace.id == draggedWorkspaceId
            if isCandidate, !groupAnchorIds.contains(workspace.id) {
                movingWorkspaces.append(MovingWorkspace(
                    id: workspace.id,
                    isPinned: workspace.isPinned
                ))
            }
        }
        return OriginMetadata(
            draggedWorkspaceId: draggedWorkspaceId,
            draggedIsPinned: draggedWorkspace.isPinned,
            isGroupAnchor: groupAnchorIds.contains(draggedWorkspaceId),
            movingWorkspaces: movingWorkspaces
        )
    }

    private func crossWindowTopLevelWorkspaceIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func clampedCrossWindowTopLevelSlot(
        _ proposedSlot: Int,
        draggedIsPinned: Bool,
        topLevelIds: [UUID],
        pinnedTopLevelIds: Set<UUID>
    ) -> Int {
        let clampedSlot = max(0, min(proposedSlot, topLevelIds.count))
        let pinnedCount = topLevelIds.reduce(into: 0) { count, workspaceId in
            if pinnedTopLevelIds.contains(workspaceId) {
                count += 1
            }
        }
        return draggedIsPinned
            ? min(clampedSlot, pinnedCount)
            : max(clampedSlot, pinnedCount)
    }

    private func crossWindowRawInsertIndex(
        forTopLevelSlot slot: Int,
        topLevelIds: [UUID]
    ) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        return tabManager.tabs.firstIndex { $0.id == topLevelId }
            ?? tabManager.tabs.count
    }

    private func syncSelectionAfterReorder(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy()
            .reconciledSelection(
                previousSelectionIds: previousSelectionIds,
                liveWorkspaceIds: liveWorkspaceIds,
                fallbackSelectedWorkspaceId: tabManager.selectedTabId
            )
        state.setSelectedWorkspaceIds(nextSelectionIds)
        tabManager.setSidebarSelectedWorkspaceIds(nextSelectionIds)
        state.setLastSelectionIndex(
            SidebarWorkspaceSelectionSyncPolicy()
                .anchorIndexAfterWorkspaceReorder(
                    preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
                    selectedWorkspaceIds: nextSelectionIds,
                    focusedWorkspaceId: tabManager.selectedTabId,
                    liveWorkspaceIds: liveWorkspaceIds
                )
        )
        state.selectTabsPage()
    }

    private func applySelection(
        _ workspaceIds: Set<UUID>,
        preferredWorkspaceId: UUID?
    ) {
        state.setSelectedWorkspaceIds(workspaceIds)
        tabManager.setSidebarSelectedWorkspaceIds(workspaceIds)
        state.setLastSelectionIndex(
            preferredWorkspaceId.flatMap { preferredWorkspaceId in
                tabManager.tabs.firstIndex { $0.id == preferredWorkspaceId }
            }
        )
        state.selectTabsPage()
    }

    private func finishWorkspaceDrag(_ draggedWorkspaceId: UUID) {
        let ownsSourceSession = activeSession?.draggedWorkspaceId
            == draggedWorkspaceId
        workspaceDragRegistry.end(workspaceId: draggedWorkspaceId)
        if ownsSourceSession,
           Self.originMetadata?.draggedWorkspaceId == draggedWorkspaceId {
            Self.originMetadata = nil
        }
        if ownsSourceSession {
            activeSession = nil
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: nil,
                reason: "appkit_drag_end"
            )
        }
        proposedDrop = nil
    }
}
