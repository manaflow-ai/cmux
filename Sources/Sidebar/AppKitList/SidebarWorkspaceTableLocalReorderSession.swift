import AppKit
import CmuxFoundation

/// What the local-reorder session needs from the table controller: row state,
/// animated permutation, plan resolution/commit (both route through the same
/// resolver the drop path has always used), and lifecycle notifications.
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
/// rows animate apart around the moving slot. The system drag session stays
/// alive underneath — its image is hidden while the drag is over this
/// sidebar, so cross-window drops keep today's behavior — and the model is
/// only mutated once, on drop, from the same resolved plan the preview shows.
@MainActor
final class SidebarWorkspaceTableLocalReorderController {
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
        var grabOffsetY: CGFloat
        var blockHeight: CGFloat
        var lastPlan: SidebarWorkspaceReorderDropPlan?
        var lastPoint: CGPoint?
        var floatingView: SidebarWorkspaceReorderFloatingRowView?
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

    /// Starts a local session when the system drag begins. `screenPoint` is
    /// the drag origin used to compute the pointer's grab offset inside the
    /// dragged block.
    func sessionWillBegin(
        _ draggingSession: NSDraggingSession,
        draggedWorkspaceId: UUID,
        at screenPoint: NSPoint
    ) {
        guard case .idle = phase,
              let delegate,
              let container = delegate.localReorderContainerView else { return }
        let rows = delegate.localReorderRows
        guard let block = Self.blockRowIndices(rows: rows, draggedWorkspaceId: draggedWorkspaceId),
              !block.isEmpty else { return }

        let overlay = container.reorderDropView
        let table = container.tableView
        let blockRect = block.reduce(CGRect.null) { partial, row in
            partial.union(table.convert(table.rect(ofRow: row), to: overlay))
        }
        guard !blockRect.isNull, blockRect.height > 0 else { return }

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
        var next = Session(
            draggedWorkspaceId: draggedWorkspaceId,
            isGroupBlock: rows[block[0]].isGroupHeader,
            baseGroupId: baseGroupId,
            destinationGroupId: baseGroupId,
            blockRowIds: block.map { rows[$0].id },
            originalOrder: rows.map(\.id),
            grabOffsetY: min(max(pointerY - blockRect.minY, 0), blockRect.height),
            blockHeight: blockRect.height,
            sourceDragImageProviders: sourceDragImageProviders(
                in: draggingSession,
                relativeTo: overlay
            )
        )
        next.floatingView = floating
        session = next
        phase = .dragging(insideSidebar: true)

        hiddenRowIds = Set(next.blockRowIds)
        delegate.localReorderSetCellsHidden(hiddenRowIds)
        overlay.addSubview(floating)
        setSourceDragImage(hidden: true, in: draggingSession)
#if DEBUG
        cmuxDebugLog(
            "sidebar.localReorder.begin screen=(\(screenPoint.x),\(screenPoint.y)) " +
            "point=(\(pointerY)) band=\(sidebarBand(in: overlay)) " +
            "corridor=\(Self.reorderCorridor(for: sidebarBand(in: overlay)))"
        )
#endif
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
    /// animate rows to the order that plan produces.
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
            animated: true
        )
        session?.lastPlan = nil
        session?.destinationGroupId = current.baseGroupId
    }

    /// Drop landed on this sidebar: commit the previewed plan and settle the
    /// floating row into its slot. Returns false when no local session owns
    /// this drop (foreign drags keep the existing path).
    func handlePerformDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlayTarget]
    ) -> Bool {
        guard let current = session, case .dragging = phase, let delegate else { return false }
        let plan = current.lastPlan ?? delegate.localReorderResolvePlan(
            point: hitTestPoint(forPointer: point),
            targets: targets,
            stickyDestination: current.stickyDestination
        )
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
#if DEBUG
        let debugPoint = overlayPoint(fromScreen: screenPoint)
        let debugInside = debugPoint.map { point in
            guard let overlay = delegate?.localReorderContainerView?.reorderDropView else { return false }
            return Self.reorderCorridor(for: sidebarBand(in: overlay)).contains(point)
        } ?? false
        cmuxDebugLog(
            "sidebar.localReorder.end screen=(\(screenPoint.x),\(screenPoint.y)) " +
            "point=\(String(describing: debugPoint)) inside=\(debugInside ? 1 : 0) " +
            "operation=\(operation.rawValue)"
        )
#endif
        switch phase {
        case .dragging:
            if let point = overlayPoint(fromScreen: screenPoint),
               let overlay = delegate?.localReorderContainerView?.reorderDropView,
               Self.shouldCommitSourceDrop(
                   operation: operation,
                   point: point,
                   sidebarBand: sidebarBand(in: overlay)
               ) {
                // The underlying outside-sidebar destination reports `.move`,
                // but does not mutate order. The local preview owns this drop.
                draggingSession.animatesToStartingPositionsOnCancelOrFail = false
                _ = handleDragUpdate(point: point, targets: overlay.targets)
                _ = handlePerformDrop(point: point, targets: overlay.targets)
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

    /// A content-area release reports `.move` from the existing
    /// outside-sidebar destination. Escape reports no operation, so requiring
    /// `.move` preserves cancellation even when the pointer is in the corridor.
    static func shouldCommitSourceDrop(
        operation: NSDragOperation,
        point: CGPoint,
        sidebarBand: CGRect
    ) -> Bool {
        operation.contains(.move) && reorderCorridor(for: sidebarBand).contains(point)
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
        targets: [SidebarWorkspaceReorderDropOverlayTarget]
    ) {
        guard let delegate, var current = session else { return }
        let blockPoint = hitTestPoint(forPointer: point)
        guard let plan = delegate.localReorderResolvePlan(
            point: blockPoint,
            targets: targets,
            stickyDestination: current.stickyDestination
        ) else {
            // A nil plan is the planner's no-op suppression: the drop would
            // land the block at its model position. Two very different zones
            // produce it, and conflating them oscillates (restore moves a
            // neighbor under the pointer, which re-previews, which restores…):
            // - Pointer inside the block's own preview frame — the gap under
            //   the pointer IS the block; the resting state of every drag.
            //   Keep the preview exactly as it is.
            // - Pointer outside the block — it crossed into the original
            //   slot's dead zone (or an illegal one). Preview the original
            //   order and forget the plan so the drop restores; this is what
            //   lets a drag be returned exactly where it started.
            if pointerIsInsideBlockPreviewFrame(pointerY: blockPoint.y) {
                return
            }
            current.lastPlan = nil
            current.destinationGroupId = current.baseGroupId
            session = current
            delegate.localReorderApplyOrder(
                current.originalOrder,
                movedRowIds: current.blockRowIds,
                animated: true
            )
            updateFloatingIndent(destinationGroupId: current.baseGroupId)
            return
        }
        // The destination group comes from the commit action, not the
        // indicator render scope: root-lane group-boundary plans render with
        // a group scope while committing a top-level move.
        guard case .reorder(_, _, let explicitGroupId) = plan.action else { return }
        current.lastPlan = plan
        let rows = delegate.localReorderRows
        let previewRows = rows.map {
            SidebarWorkspaceReorderPreviewRow(
                workspaceId: $0.workspaceId,
                groupId: $0.groupId,
                isGroupHeader: $0.isGroupHeader
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
            session = current
            delegate.localReorderApplyOrder(
                preview.order.map { rows[$0].id },
                movedRowIds: current.blockRowIds,
                animated: true
            )
            updateFloatingIndent(destinationGroupId: preview.destinationGroupId)
        } else {
            session = current
        }
    }

    /// Whether the pointer sits within the dragged block's rows as the
    /// preview currently shows them (overlay coordinates).
    private func pointerIsInsideBlockPreviewFrame(pointerY: CGFloat) -> Bool {
        guard let current = session,
              let container = delegate?.localReorderContainerView else { return false }
        let rows = delegate?.localReorderRows ?? []
        let table = container.tableView
        let overlay = container.reorderDropView
        let blockRect = rows.indices
            .filter { current.blockRowIds.contains(rows[$0].id) }
            .reduce(CGRect.null) { partial, row in
                partial.union(table.convert(table.rect(ofRow: row), to: overlay))
            }
        guard !blockRect.isNull else { return false }
        return pointerY >= blockRect.minY && pointerY <= blockRect.maxY
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
    private func updateFloatingIndent(destinationGroupId: UUID?) {
        guard let current = session, !current.isGroupBlock,
              let floating = current.floatingView else { return }
        let destination: CGFloat = destinationGroupId != nil
            ? SidebarWorkspaceGroupingMetrics.memberIndent
            : 0
        let base: CGFloat = current.baseGroupId != nil
            ? SidebarWorkspaceGroupingMetrics.memberIndent
            : 0
        floating.setIndent(destination - base, animationDuration: slideDuration)
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
            animated: true
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
