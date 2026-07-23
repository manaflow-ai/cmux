import AppKit
import CmuxFoundation

/// What the local-reorder session needs from the table controller: row state,
/// synchronous preview permutation, plan resolution/commit (both route
/// through the same resolver the drop path has always used), and lifecycle
/// notifications.
@MainActor
protocol SidebarWorkspaceTableLocalReorderDelegate: AnyObject {
    var localReorderContainerView: SidebarWorkspaceTableContainerView? { get }
    var localReorderRows: [SidebarWorkspaceTableRowConfiguration] { get }
    func localReorderApplyOrder(
        _ ids: [SidebarWorkspaceRenderItemID],
        movedRowIds: [SidebarWorkspaceRenderItemID],
        animated: Bool
    )
    func localReorderSetCellsHidden(_ ids: Set<SidebarWorkspaceRenderItemID>)
    func localReorderResolvePlan(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlayTarget],
        stickyDestination: SidebarWorkspaceReorderStickyDestination
    ) -> SidebarWorkspaceReorderDropPlan?
    func localReorderCommit(plan: SidebarWorkspaceReorderDropPlan) -> Bool
    func localReorderUpdateAutoscroll()
    func localReorderSessionDidEnd(flushDeferredApply: Bool)
}

/// Chrome-style live reorder for drags that originate in this table: the
/// dragged row (or whole group block) floats under the pointer while sibling
/// rows open a gap around the moving slot. The table's direct pointer tracker
/// is the primary owner. AppKit's system drag is used only after an explicit
/// cross-window handoff, and remains supported here for legacy source paths.
/// The model is mutated once, on drop, from the plan the preview shows.
@MainActor
final class SidebarWorkspaceTableLocalReorderController {
    /// Immutable pickup-time row data. Live table rows are animated preview
    /// output, so feeding their geometry back into resolution creates a
    /// planner/UI feedback loop. The session lays this snapshot out itself.
    private struct PickupRow {
        let configuration: SidebarWorkspaceTableRowConfiguration
        let height: CGFloat
    }

    private enum Phase {
        case idle
        /// Drag in flight. `insideSidebar` tracks whether the preview or the
        /// system drag image is the active visual.
        case dragging(insideSidebar: Bool)
        /// Drop committed; the floating row is animating into its slot.
        case settling
        /// Cancelled; rows are animating back to the original order.
        case restoring
    }

    private struct Session {
        let draggedWorkspaceId: UUID
        let isGroupBlock: Bool
        /// The dragged workspace row's group at pickup: the snapshot was
        /// captured with this indent baked in, so indent previews offset
        /// relative to it.
        var baseGroupId: UUID?
        /// The group the preview currently targets; feeds the resolver's
        /// sticky boundary handling and the indent preview.
        var destinationGroupId: UUID?
        var blockRowIds: [SidebarWorkspaceRenderItemID]
        var originalOrder: [SidebarWorkspaceRenderItemID]
        let pickupRows: [PickupRow]
        let logicalContentMinY: CGFloat
        let rowSpacing: CGFloat
        /// The order currently previewed by the table. This and `lastPlan`
        /// are the coordinator's state; animated table geometry is output.
        var previewOrder: [SidebarWorkspaceRenderItemID]
        var grabOffsetY: CGFloat
        var blockHeight: CGFloat
        var lastPlan: SidebarWorkspaceReorderDropPlan?
        var lastPoint: CGPoint?
        var floatingView: SidebarWorkspaceReorderFloatingRowView?
        var explicitlyCancelled = false
        var sourceDragImageHidden = false
        var sourceDragImageProviders: [(() -> [NSDraggingImageComponent])?]

        /// Boundary decisions bias toward where the drag already previews
        /// (blocks always stay top-level).
        var stickyDestination: SidebarWorkspaceReorderStickyDestination {
            if isGroupBlock { return .topLevel }
            if let destinationGroupId { return .group(destinationGroupId) }
            return .topLevel
        }
    }

    weak var delegate: SidebarWorkspaceTableLocalReorderDelegate?

    private var phase: Phase = .idle
    private var session: Session?
    private var pendingApply: (() -> Void)?
    private let slideDuration: TimeInterval = 0.16

    /// Rows whose cells stay hidden (they form the moving gap).
    private(set) var hiddenRowIds: Set<SidebarWorkspaceRenderItemID> = []

    /// Whether a drag that originated in this table is being previewed.
    var isSessionActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Whether row applies must be deferred (drag in flight or end animation
    /// still running).
    var defersApplies: Bool { isSessionActive }

    // MARK: - Session lifecycle (driven by the table controller)

    /// Starts a local session when the system drag begins. This is the legacy
    /// and modifier-drag path; ordinary row drags use `directSessionWillBegin`.
    func sessionWillBegin(
        _ draggingSession: NSDraggingSession,
        draggedWorkspaceId: UUID,
        at screenPoint: NSPoint
    ) {
        _ = beginSession(
            draggingSession: draggingSession,
            draggedWorkspaceId: draggedWorkspaceId,
            at: screenPoint
        )
    }

    /// Starts the direct pointer-owned path without creating an
    /// `NSDraggingSession`. Returns false when pickup geometry is unavailable.
    @discardableResult
    func directSessionWillBegin(
        draggedWorkspaceId: UUID,
        at screenPoint: NSPoint
    ) -> Bool {
        beginSession(
            draggingSession: nil,
            draggedWorkspaceId: draggedWorkspaceId,
            at: screenPoint
        )
    }

    @discardableResult
    private func beginSession(
        draggingSession: NSDraggingSession?,
        draggedWorkspaceId: UUID,
        at screenPoint: NSPoint
    ) -> Bool {
        guard case .idle = phase,
              let delegate,
              let container = delegate.localReorderContainerView else { return false }
        let rows = delegate.localReorderRows
        guard let block = Self.blockRowIndices(rows: rows, draggedWorkspaceId: draggedWorkspaceId),
              !block.isEmpty else { return false }

        let overlay = container.reorderDropView
        let table = container.tableView
        let blockRect = block.reduce(CGRect.null) { partial, row in
            partial.union(table.convert(table.rect(ofRow: row), to: overlay))
        }
        guard !blockRect.isNull, blockRect.height > 0 else { return false }

        let floating = SidebarWorkspaceReorderFloatingRowView(
            snapshots: Self.blockSnapshots(table: table, rowIndexes: block),
            totalRowCount: block.count,
            frame: blockRect
        )

        let pointerY: CGFloat
        if let window = container.window {
            pointerY = overlay.convert(window.convertPoint(fromScreen: screenPoint), from: nil).y
        } else {
            pointerY = blockRect.midY
        }

        let baseGroupId = rows[block[0]].isGroupHeader ? nil : rows[block[0]].groupId
        let originalOrder = rows.map(\.id)
        var next = Session(
            draggedWorkspaceId: draggedWorkspaceId,
            isGroupBlock: rows[block[0]].isGroupHeader,
            baseGroupId: baseGroupId,
            destinationGroupId: baseGroupId,
            blockRowIds: block.map { rows[$0].id },
            originalOrder: originalOrder,
            pickupRows: rows.indices.map { row in
                PickupRow(configuration: rows[row], height: table.rect(ofRow: row).height)
            },
            logicalContentMinY: rows.isEmpty ? 0 : table.rect(ofRow: 0).minY,
            rowSpacing: table.intercellSpacing.height,
            previewOrder: originalOrder,
            grabOffsetY: min(max(pointerY - blockRect.minY, 0), blockRect.height),
            blockHeight: blockRect.height,
            sourceDragImageProviders: draggingSession.map {
                sourceDragImageProviders(in: $0, relativeTo: overlay)
            } ?? []
        )
        next.floatingView = floating
        session = next
        phase = .dragging(insideSidebar: true)

        hiddenRowIds = Set(next.blockRowIds)
        delegate.localReorderSetCellsHidden(hiddenRowIds)
        overlay.addSubview(floating)
        if let draggingSession {
            setSourceDragImage(hidden: true, in: draggingSession)
        }
#if DEBUG
        cmuxDebugLog(
            "sidebar.localReorder.begin screen=(\(screenPoint.x),\(screenPoint.y)) " +
            "point=(\(pointerY)) band=\(sidebarBand(in: overlay)) " +
            "corridor=\(Self.reorderCorridor(for: sidebarBand(in: overlay)))"
        )
#endif
        return true
    }

    /// Direct pointer update in screen coordinates. The pointer can be over
    /// the terminal or another in-window view; X is clamped to the sidebar by
    /// `hitTestPoint`, while Y continues to drive the reorder.
    @discardableResult
    func directSessionMoved(to screenPoint: NSPoint) -> Bool {
        guard let point = overlayPoint(fromScreen: screenPoint),
              let overlay = delegate?.localReorderContainerView?.reorderDropView else { return false }
        return handleDragUpdate(point: point, targets: overlay.targets)
    }

    /// Commits from the exact final pointer position owned by the direct
    /// tracker. No destination callback can race this transition.
    @discardableResult
    func directSessionEnded(at screenPoint: NSPoint) -> Bool {
        guard let point = overlayPoint(fromScreen: screenPoint),
              let overlay = delegate?.localReorderContainerView?.reorderDropView else {
            cancelAndRestore()
            return false
        }
        return handlePerformDrop(point: point, targets: overlay.targets)
    }

    func directSessionCancelled() {
        cancelAndRestore()
    }

    /// Tears the local renderer down before the table starts the one-way
    /// system-drag handoff. The system drag then becomes the sole owner.
    func directSessionHandedOffToSystemDrag() {
        guard let current = session, let delegate else {
            finish(flushDeferredApply: false)
            return
        }
        delegate.localReorderApplyOrder(
            current.originalOrder,
            movedRowIds: current.blockRowIds,
            animated: false
        )
        finish(flushDeferredApply: false)
    }

    /// Destination-side image hiding: while the drag is over this sidebar the
    /// floating row is the visual, so the system snapshot is suppressed. The
    /// suppression reverts automatically when the drag exits the destination,
    /// which is exactly the cross-window behavior we want.
    func draggingEntered(_ sender: NSDraggingInfo) {
        guard session != nil, case .dragging = phase else { return }
        hideDragImage(sender)
        setInsideSidebar(true)
    }

    /// Source-side motion remains available after the pointer leaves the
    /// sidebar's view hierarchy. It is therefore authoritative for the local
    /// reorder corridor, unlike destination callbacks, which stop at the
    /// sidebar edge.
    func draggingSession(
        _ draggingSession: NSDraggingSession,
        movedTo screenPoint: NSPoint
    ) {
        guard session != nil, case .dragging = phase,
              let point = overlayPoint(fromScreen: screenPoint),
              let overlay = delegate?.localReorderContainerView?.reorderDropView else { return }

        let isInsideCorridor = Self.reorderCorridor(for: sidebarBand(in: overlay)).contains(point)
#if DEBUG
        cmuxDebugLog(
            "sidebar.localReorder.sourceMove screen=(\(screenPoint.x),\(screenPoint.y)) " +
            "point=(\(point.x),\(point.y)) inside=\(isInsideCorridor ? 1 : 0)"
        )
#endif
        if isInsideCorridor {
            setSourceDragImage(hidden: true, in: draggingSession)
            _ = handleDragUpdate(point: point, targets: overlay.targets)
        } else {
            setSourceDragImage(hidden: false, in: draggingSession)
            leaveReorderCorridor()
        }
    }

    /// Continuous preview: resolve the same plan the drop would commit and
    /// synchronously open the gap that plan produces.
    /// Returns false when this drag isn't a live local session (foreign drag
    /// or degraded session) so the caller falls back to the indicator path.
    func handleDragUpdate(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlayTarget]
    ) -> Bool {
        guard var current = session, case .dragging = phase, let delegate else { return false }
        setInsideSidebar(true)
        current.lastPoint = point
        session = current
        positionFloatingView(pointerY: point.y)
        delegate.localReorderUpdateAutoscroll()
        resolveAndApplyPreview(point: point, targets: targets)
        return true
    }

    /// Slot decisions key off the floating block's geometry, not the raw
    /// cursor: the swap fires when the block's vertical center crosses a
    /// neighbor's midpoint, wherever inside the row the user grabbed it. The
    /// x clamps into the sidebar band so a pointer in the source-tracked
    /// outside-sidebar corridor hit-tests as if it were still over the rows.
    private func hitTestPoint(forPointer point: CGPoint) -> CGPoint {
        guard let current = session,
              let container = delegate?.localReorderContainerView else { return point }
        let overlay = container.reorderDropView
        let band = sidebarBand(in: overlay)
        let top = floatingTop(forPointerY: point.y, blockHeight: current.blockHeight, band: band)
        return CGPoint(
            x: min(max(point.x, band.minX), band.maxX),
            y: top + current.blockHeight / 2
        )
    }

    /// The floating block's clamped top edge for a pointer position, kept in
    /// one place so the visual and the hit test can never disagree.
    private func floatingTop(forPointerY pointerY: CGFloat, blockHeight: CGFloat, band: CGRect) -> CGFloat {
        let minY = band.minY
        let maxY = max(minY, band.maxY - blockHeight)
        guard let current = session else { return minY }
        return min(max(pointerY - current.grabOffsetY, minY), maxY)
    }

    /// Destination exit alone is not a reorder exit: the source-session
    /// callback continues tracking through the corridor outside the sidebar.
    func draggingExited() {
        // Source-side `draggingSession(_:movedTo:)` decides whether the pointer
        // left the reorder corridor and restores only when it truly did.
    }

    /// Pointer left the reorder corridor: restore the original order because
    /// the item may be headed to another window, and restore the system drag
    /// image as the active visual.
    private func leaveReorderCorridor() {
        guard let current = session, case .dragging = phase, let delegate else { return }
        setInsideSidebar(false)
        delegate.localReorderApplyOrder(
            current.originalOrder,
            movedRowIds: current.blockRowIds,
            animated: false
        )
        session?.lastPlan = nil
        session?.destinationGroupId = current.baseGroupId
        session?.previewOrder = current.originalOrder
    }

    /// Drop landed on this sidebar: commit the previewed plan and settle the
    /// floating row into its slot. Returns false when no local session owns
    /// this drop (foreign drags keep the existing path).
    func handlePerformDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlayTarget]
    ) -> Bool {
        guard session != nil, case .dragging = phase, let delegate else { return false }
        // The same transition owns the final pointer update and the commit.
        // This prevents a destination callback from committing a stale plan.
        resolveAndApplyPreview(point: point, targets: targets)
        guard let current = session else { return false }
        let plan = current.lastPlan
        guard let plan else {
            cancelAndRestore()
            return true
        }
        // Pre-commit deferred applies are superseded by the apply the commit
        // itself publishes; applies arriving during the settle animation are
        // deferred and flushed when it completes.
        pendingApply = nil
        let committed = delegate.localReorderCommit(plan: plan)
        guard committed else {
            cancelAndRestore()
            return true
        }
        phase = .settling
        settleFloatingViewIntoSlot()
        return true
    }

    /// System drag session ended. A release inside the source-tracked reorder
    /// corridor commits even if the destination under the cursor was the
    /// content area's outside-sidebar reset overlay. A release beyond the
    /// corridor remains a cancel/cross-window handoff.
    func sessionEnded(
        _ draggingSession: NSDraggingSession,
        at screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard session != nil else { return }
        // For a source-side release over a view that declines the drop,
        // NSTableView reports the drag origin as `endedAt`. The global mouse
        // location remains the real release point and is therefore the final
        // input to the coordinator. Explicit Escape is tracked separately.
        let releaseScreenPoint = NSEvent.mouseLocation
#if DEBUG
        let debugPoint = overlayPoint(fromScreen: releaseScreenPoint)
        let debugInside = debugPoint.map { point in
            guard let overlay = delegate?.localReorderContainerView?.reorderDropView else { return false }
            return Self.reorderCorridor(for: sidebarBand(in: overlay)).contains(point)
        } ?? false
        cmuxDebugLog(
            "sidebar.localReorder.end reported=(\(screenPoint.x),\(screenPoint.y)) " +
            "mouse=(\(releaseScreenPoint.x),\(releaseScreenPoint.y)) " +
            "point=\(String(describing: debugPoint)) inside=\(debugInside ? 1 : 0) " +
            "operation=\(operation.rawValue)"
        )
#endif
        switch phase {
        case .dragging:
            if let point = overlayPoint(fromScreen: releaseScreenPoint),
               let overlay = delegate?.localReorderContainerView?.reorderDropView {
                // Resolve the final source point first. AppKit may report no
                // destination operation even for a normal mouse-up, so the
                // coordinator's valid plan is the local-drop authority.
                _ = handleDragUpdate(point: point, targets: overlay.targets)
                let current = session
                let explicitlyCancelled = current?.explicitlyCancelled == true
                    || Self.isEscapeCancellationEvent(NSApp.currentEvent)
                if Self.shouldCommitSourceDrop(
                    hasResolvedPlan: current?.lastPlan != nil,
                    explicitlyCancelled: explicitlyCancelled,
                    point: point,
                    sidebarBand: sidebarBand(in: overlay)
                ) {
                    draggingSession.animatesToStartingPositionsOnCancelOrFail = false
                    _ = handlePerformDrop(point: point, targets: overlay.targets)
                } else {
                    cancelAndRestore()
                }
            } else {
                cancelAndRestore()
            }
        case .idle, .settling, .restoring:
            break
        }
    }

    /// Autoscroll moved rows under a stationary pointer: re-resolve the
    /// preview against the refreshed target geometry.
    func viewportDidChange() {
        guard let current = session, case .dragging(true) = phase,
              let point = current.lastPoint,
              let overlay = delegate?.localReorderContainerView?.reorderDropView else { return }
        resolveAndApplyPreview(point: point, targets: overlay.targets)
    }

    /// An authoritative apply landed mid-session. Content-only changes are
    /// deferred (flushed when the session ends); structural changes degrade
    /// the session so the apply proceeds normally and the rest of the drag
    /// falls back to the indicator path.
    /// Returns true when the apply should be deferred.
    func shouldDeferApply(
        nextRowIds: [SidebarWorkspaceRenderItemID],
        deferred: @escaping () -> Void
    ) -> Bool {
        guard isSessionActive else { return false }
        let currentIds = delegate?.localReorderRows.map(\.id) ?? []
        if Set(nextRowIds) == Set(currentIds), nextRowIds.count == currentIds.count {
            pendingApply = deferred
            return true
        }
        degrade()
        return false
    }

    // MARK: - Internals

    private func setInsideSidebar(_ inside: Bool) {
        guard case .dragging(let wasInside) = phase, wasInside != inside else { return }
        phase = .dragging(insideSidebar: inside)
        session?.floatingView?.isHidden = !inside
    }

    /// Corridor geometry is deliberately independent of the overlay's frame:
    /// extending a child view past its parent does not extend AppKit drag
    /// destination routing. Source-session motion uses this expanded band.
    static func reorderCorridor(for sidebarBand: CGRect) -> CGRect {
        CGRect(
            x: sidebarBand.minX - 80,
            y: sidebarBand.minY - 60,
            width: sidebarBand.width + 80 + 240,
            height: sidebarBand.height + 60 + 100
        )
    }

    /// The coordinator's resolved plan owns local commit intent. AppKit can
    /// report `.none` for a normal source-side release, so cancellation is
    /// represented explicitly instead of inferred from the drag operation.
    static func shouldCommitSourceDrop(
        hasResolvedPlan: Bool,
        explicitlyCancelled: Bool,
        point: CGPoint,
        sidebarBand: CGRect
    ) -> Bool {
        hasResolvedPlan
            && !explicitlyCancelled
            && reorderCorridor(for: sidebarBand).contains(point)
    }

    /// AppKit normally routes Escape through `cancelOperation`, but retain the
    /// terminating key event as a second explicit signal for older macOS.
    static func isEscapeCancellationEvent(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown || event.type == .keyUp else { return false }
        return event.keyCode == 53
    }

    /// Records user cancellation while the AppKit drag loop still owns input.
    /// The session ends normally afterward and restores instead of committing.
    @discardableResult
    func cancelOperation() -> Bool {
        guard session != nil, case .dragging = phase else { return false }
        session?.explicitlyCancelled = true
        return true
    }

    private func sidebarBand(in overlay: NSView) -> CGRect {
        guard let container = delegate?.localReorderContainerView else { return overlay.bounds }
        return overlay.convert(container.scrollView.frame, from: container)
    }

    private func overlayPoint(fromScreen screenPoint: NSPoint) -> CGPoint? {
        guard let container = delegate?.localReorderContainerView,
              let window = container.window else { return nil }
        return container.reorderDropView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    }

    private func sourceDragImageProviders(
        in draggingSession: NSDraggingSession,
        relativeTo view: NSView
    ) -> [(() -> [NSDraggingImageComponent])?] {
        var providers: [(() -> [NSDraggingImageComponent])?] = []
        draggingSession.enumerateDraggingItems(
            options: [],
            for: view,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, index, _ in
            while providers.count <= index { providers.append(nil) }
            providers[index] = item.imageComponentsProvider
        }
        return providers
    }

    private func setSourceDragImage(hidden: Bool, in draggingSession: NSDraggingSession) {
        guard var current = session, current.sourceDragImageHidden != hidden,
              let view = delegate?.localReorderContainerView?.reorderDropView else { return }
        draggingSession.enumerateDraggingItems(
            options: [],
            for: view,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, index, _ in
            item.imageComponentsProvider = hidden
                ? { [] }
                : current.sourceDragImageProviders.indices.contains(index)
                    ? current.sourceDragImageProviders[index]
                    : nil
        }
        current.sourceDragImageHidden = hidden
        session = current
    }

    private func hideDragImage(_ sender: NSDraggingInfo) {
        guard let container = delegate?.localReorderContainerView else { return }
        sender.enumerateDraggingItems(
            options: [],
            for: container.reorderDropView,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, _ in
            item.imageComponentsProvider = { [] }
        }
    }

    private func resolveAndApplyPreview(
        point: CGPoint,
        targets _: [SidebarWorkspaceReorderDropOverlayTarget]
    ) {
        guard let delegate, var current = session else { return }
        let blockPoint = hitTestPoint(forPointer: point)
        let targets = logicalTargets(for: current)
        let plan = delegate.localReorderResolvePlan(
            point: blockPoint,
            targets: targets,
            stickyDestination: current.stickyDestination
        )
        guard let plan else {
            // With the dragged block absent from logical hit targets, nil has
            // one meaning: this is the original/invalid slot. Restore it.
            current.lastPlan = nil
            current.destinationGroupId = current.baseGroupId
            current.previewOrder = current.originalOrder
            session = current
            delegate.localReorderApplyOrder(
                current.originalOrder,
                movedRowIds: current.blockRowIds,
                animated: false
            )
            updateFloatingIndent(destinationGroupId: current.baseGroupId, animated: false)
            return
        }
        // The destination group comes from the commit action, not the
        // indicator render scope: root-lane group-boundary plans render with
        // a group scope while committing a top-level move.
        guard case .reorder(_, _, let explicitGroupId) = plan.action else { return }
        current.lastPlan = plan
        let previewRows = current.pickupRows.map {
            SidebarWorkspaceReorderPreviewRow(
                workspaceId: $0.configuration.workspaceId,
                groupId: $0.configuration.groupId,
                isGroupHeader: $0.configuration.isGroupHeader
            )
        }
        if let indicator = plan.indicator,
           let preview = SidebarWorkspaceReorderPreviewPermutation().previewOrder(
               rows: previewRows,
               draggedWorkspaceId: current.draggedWorkspaceId,
               indicator: indicator,
               scope: plan.indicatorScope,
               destinationGroupId: explicitGroupId
           ) {
            current.destinationGroupId = preview.destinationGroupId
            current.previewOrder = preview.order.map {
                current.pickupRows[$0].configuration.id
            }
            session = current
            delegate.localReorderApplyOrder(
                current.previewOrder,
                movedRowIds: current.blockRowIds,
                animated: false
            )
            updateFloatingIndent(destinationGroupId: preview.destinationGroupId, animated: false)
        } else {
            session = current
        }
    }

    /// Reconstructs drop targets from the immutable pickup snapshot and the
    /// coordinator's preview order. The dragged block occupies layout space
    /// but has no target, producing a real logical gap under the pointer.
    /// Animated NSTableView frames never become planner input.
    private func logicalTargets(for current: Session) -> [SidebarWorkspaceReorderDropOverlayTarget] {
        guard let container = delegate?.localReorderContainerView else { return [] }
        let table = container.tableView
        let overlay = container.reorderDropView
        let rowsById = Dictionary(
            uniqueKeysWithValues: current.pickupRows.map { ($0.configuration.id, $0) }
        )
        let blockIds = Set(current.blockRowIds)
        var y = current.logicalContentMinY
        var targets: [SidebarWorkspaceReorderDropOverlayTarget] = []
        targets.reserveCapacity(max(0, current.previewOrder.count - blockIds.count))
        for id in current.previewOrder {
            guard let row = rowsById[id] else { continue }
            let tableFrame = CGRect(
                x: table.bounds.minX,
                y: y,
                width: table.bounds.width,
                height: row.height
            )
            if !blockIds.contains(id) {
                let configuration = row.configuration
                targets.append(SidebarWorkspaceReorderDropOverlayTarget(
                    workspaceId: configuration.workspaceId,
                    groupId: configuration.groupId,
                    isGroupHeader: configuration.isGroupHeader,
                    frame: table.convert(tableFrame, to: overlay)
                ))
            }
            y += row.height + current.rowSpacing
        }
        return targets
    }

    private func positionFloatingView(pointerY: CGFloat) {
        guard let current = session,
              let floating = current.floatingView,
              let container = delegate?.localReorderContainerView else { return }
        // Clamp to the sidebar band so the block never floats over the
        // terminal or past the list edges while the pointer uses the corridor.
        let overlay = container.reorderDropView
        let band = sidebarBand(in: overlay)
        var frame = floating.frame
        frame.origin.y = floatingTop(
            forPointerY: pointerY,
            blockHeight: current.blockHeight,
            band: band
        )
        floating.frame = frame
    }

    /// Offsets the floating snapshot relative to how it was captured: a
    /// top-level row joining a group indents by the member indent, a member
    /// row leaving its group un-indents, and returning to the source group
    /// (or staying top-level) sits at zero.
    private func updateFloatingIndent(destinationGroupId: UUID?, animated: Bool = true) {
        guard let current = session, !current.isGroupBlock,
              let floating = current.floatingView else { return }
        let destination: CGFloat = destinationGroupId != nil
            ? SidebarWorkspaceGroupingMetrics.memberIndent
            : 0
        let base: CGFloat = current.baseGroupId != nil
            ? SidebarWorkspaceGroupingMetrics.memberIndent
            : 0
        floating.setIndent(destination - base, animationDuration: animated ? slideDuration : 0)
    }

    private func settleFloatingViewIntoSlot() {
        guard let delegate,
              let container = delegate.localReorderContainerView,
              let current = session else {
            finish(flushDeferredApply: true)
            return
        }
        let rows = delegate.localReorderRows
        let table = container.tableView
        let overlay = container.reorderDropView
        let blockRowIndexes = rows.indices.filter { current.blockRowIds.contains(rows[$0].id) }
        let targetRect = blockRowIndexes.reduce(CGRect.null) { partial, row in
            partial.union(table.convert(table.rect(ofRow: row), to: overlay))
        }
        guard let floating = current.floatingView, !targetRect.isNull else {
            finish(flushDeferredApply: true)
            return
        }
        animateEndOfSession(floating: floating, to: targetRect)
    }

    private func cancelAndRestore() {
        guard let delegate, let current = session else {
            finish(flushDeferredApply: true)
            return
        }
        phase = .restoring
        delegate.localReorderApplyOrder(
            current.originalOrder,
            movedRowIds: current.blockRowIds,
            animated: false
        )
        guard let container = delegate.localReorderContainerView,
              let floating = current.floatingView,
              !floating.isHidden else {
            finish(flushDeferredApply: true)
            return
        }
        let rows = delegate.localReorderRows
        let table = container.tableView
        let overlay = container.reorderDropView
        let blockRowIndexes = rows.indices.filter { current.blockRowIds.contains(rows[$0].id) }
        let targetRect = blockRowIndexes.reduce(CGRect.null) { partial, row in
            partial.union(table.convert(table.rect(ofRow: row), to: overlay))
        }
        guard !targetRect.isNull else {
            finish(flushDeferredApply: true)
            return
        }
        // The block is going back where it came from; any indent preview
        // slides back to the captured position.
        updateFloatingIndent(destinationGroupId: current.baseGroupId)
        animateEndOfSession(floating: floating, to: targetRect)
    }

    /// Slides the floating block into `targetRect`, then unhides the real
    /// cells underneath and tears the session down. The indent offset is the
    /// caller's: a commit into a group keeps the indented content so it lands
    /// exactly where the member cell will render.
    private func animateEndOfSession(
        floating: SidebarWorkspaceReorderFloatingRowView,
        to targetRect: CGRect
    ) {
        floating.settle()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            floating.animator().frame = targetRect
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                self?.finish(flushDeferredApply: true)
            }
        }
    }

    /// Instant teardown: an authoritative structural apply owns the table
    /// now. The system drag may still be in flight; without a session the
    /// update path falls back to the classic indicator handling.
    private func degrade() {
        finish(flushDeferredApply: false)
    }

    private func finish(flushDeferredApply: Bool) {
        // A degrade can land while an end animation is in flight; its
        // completion handler must not tear down (and notify for) a session
        // that already ended.
        if session == nil, pendingApply == nil, hiddenRowIds.isEmpty {
            phase = .idle
            return
        }
        session?.floatingView?.removeFromSuperview()
        session = nil
        phase = .idle
        hiddenRowIds = []
        delegate?.localReorderSetCellsHidden([])
        let pending = pendingApply
        pendingApply = nil
        delegate?.localReorderSessionDidEnd(flushDeferredApply: flushDeferredApply)
        if flushDeferredApply {
            pending?()
        }
    }

    // MARK: - Block resolution and snapshots

    /// The dragged rows as one unit: a group header plus its contiguous
    /// member rows, or a single workspace row.
    static func blockRowIndices(
        rows: [SidebarWorkspaceTableRowConfiguration],
        draggedWorkspaceId: UUID
    ) -> [Int]? {
        if let headerIndex = rows.firstIndex(where: { $0.isGroupHeader && $0.workspaceId == draggedWorkspaceId }) {
            let groupId = rows[headerIndex].groupId
            var block = [headerIndex]
            var next = headerIndex + 1
            while next < rows.count,
                  !rows[next].isGroupHeader,
                  let memberGroupId = rows[next].groupId,
                  memberGroupId == groupId {
                block.append(next)
                next += 1
            }
            return block
        }
        guard let rowIndex = rows.firstIndex(where: { !$0.isGroupHeader && $0.workspaceId == draggedWorkspaceId }) else {
            return nil
        }
        return [rowIndex]
    }

    private static let maxSnapshotRows = 3

    /// Bitmap snapshots of the block's visible cells, captured before the
    /// cells hide. Large blocks cap at a few rows; the floating view shows a
    /// count badge for the remainder.
    private static func blockSnapshots(
        table: NSTableView,
        rowIndexes: [Int]
    ) -> [SidebarWorkspaceReorderFloatingRowView.Snapshot] {
        var snapshots: [SidebarWorkspaceReorderFloatingRowView.Snapshot] = []
        for row in rowIndexes.prefix(maxSnapshotRows) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
                  cell.bounds.width > 0, cell.bounds.height > 0,
                  let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            let image = NSImage(size: cell.bounds.size)
            image.addRepresentation(rep)
            snapshots.append(SidebarWorkspaceReorderFloatingRowView.Snapshot(
                image: image,
                height: table.rect(ofRow: row).height
            ))
        }
        return snapshots
    }
}

/// The row (or group block) visual that tracks the pointer during a local
/// reorder: stacked cell snapshots with a lift shadow, X-locked to the list.
@MainActor
final class SidebarWorkspaceReorderFloatingRowView: NSView {
    struct Snapshot {
        let image: NSImage
        let height: CGFloat
    }

    /// Flipped so block snapshots stack top-down like the rows they mirror.
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    private let contentView = FlippedContentView()
    private let snapshotStack = FlippedContentView()
    private var indent: CGFloat = 0

    override var isFlipped: Bool { true }

    init(snapshots: [Snapshot], totalRowCount: Int, frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.wantsLayer = true
        // The stack slides horizontally for indent previews; the mask keeps
        // the shifted snapshot inside the row band instead of bleeding past
        // the sidebar edge.
        contentView.layer?.masksToBounds = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        snapshotStack.frame = contentView.bounds
        snapshotStack.autoresizingMask = [.width, .height]
        contentView.addSubview(snapshotStack)

        var y: CGFloat = 0
        for snapshot in snapshots {
            let imageView = NSImageView(image: snapshot.image)
            imageView.imageScaling = .scaleNone
            imageView.frame = CGRect(x: 0, y: y, width: bounds.width, height: snapshot.height)
            imageView.autoresizingMask = [.width]
            snapshotStack.addSubview(imageView)
            y += snapshot.height
        }

        let hiddenCount = totalRowCount - snapshots.count
        if hiddenCount > 0 {
            let badge = NSTextField(labelWithString: String(
                localized: "sidebar.reorder.floating.moreRows",
                defaultValue: "+\(hiddenCount)"
            ))
            badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            badge.textColor = .secondaryLabelColor
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            badge.layer?.cornerRadius = 8
            badge.alignment = .center
            badge.sizeToFit()
            let size = CGSize(width: badge.frame.width + 12, height: 16)
            badge.frame = CGRect(
                x: bounds.width - size.width - 14,
                y: y - size.height - 6,
                width: size.width,
                height: size.height
            )
            badge.autoresizingMask = [.minXMargin]
            snapshotStack.addSubview(badge)
        }

        let lift = CGFloat(1.02)
        contentView.layer?.transform = CATransform3DTranslate(
            CATransform3DMakeScale(lift, lift, 1),
            -bounds.width * (lift - 1) / (2 * lift),
            -bounds.height * (lift - 1) / (2 * lift),
            0
        )
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 3)
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Slides the snapshot horizontally by `next` points relative to its
    /// captured position: positive previews joining a group (content indents
    /// and the trailing edge clips to the narrower member width), negative
    /// previews leaving one (a member snapshot un-indents to top-level
    /// alignment). The mask keeps either direction inside the row band.
    func setIndent(_ next: CGFloat, animationDuration: TimeInterval) {
        guard indent != next else { return }
        indent = next
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var frame = snapshotStack.frame
            frame.origin.x = next
            snapshotStack.animator().frame = frame
        }
    }

    /// Drops the lift treatment so the settle animation lands flush.
    func settle() {
        contentView.layer?.transform = CATransform3DIdentity
        layer?.shadowOpacity = 0
    }
}
