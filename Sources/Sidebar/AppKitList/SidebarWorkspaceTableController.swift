import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import SwiftUI

/// Main-actor owner of the default sidebar table lifecycle and its AppKit interactions.
@MainActor
final class SidebarWorkspaceTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct DeferredRowClick {
        let rowId: SidebarWorkspaceRenderItemID
        let modifiers: NSEvent.ModifierFlags
    }

    private enum RowClickDispatchOutcome {
        case dispatched
        case awaitingActions
        case invalid
    }

    private weak var containerView: SidebarWorkspaceTableContainerView?
    private let createdCellViews = NSHashTable<NSView>.weakObjects()
    private var rows: [SidebarWorkspaceTableRowConfiguration] = []
    private var actions: SidebarWorkspaceTableActions?
    private var deferredRowClick: DeferredRowClick?
    /// SwiftUI-side wake-up for a parked click. A deferred click only lands
    /// through the next authoritative apply, and applies only happen when
    /// the deliberately Equatable-gated sidebar body re-evaluates. The park
    /// itself mutates no SwiftUI-tracked state, so without requesting an
    /// apply an idle app never re-arms the rows and the click waits on
    /// unrelated invalidation — historically an app deactivate/reactivate
    /// (issue #9690).
    var onDeferredRowClickAwaitingApply: (() -> Void)?
    private var hoveredRowId: SidebarWorkspaceRenderItemID?
    private var contextMenuRowId: SidebarWorkspaceRenderItemID?
    private var workspaceIds: [UUID] = []
    private var selectedScrollTargetWorkspaceId: UUID?
    private var isPresentationActive = true
    private var isApplyingTableGeometryUpdate = false
    private var deferredPumpHeightRowIds: Set<SidebarWorkspaceRenderItemID> = []
    private var appKitDropIndicator: SidebarDropIndicator?
    private var appKitDropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw
    private var appKitDropIndicatorIncludesRowTargets = false
    private var isWorkspaceDragSourceActive = false
    // Keep the source table alive until AppKit delivers the terminal callback.
    // SwiftUI may remove the representable (fullscreen/display changes) while
    // the native drag still owns that table.
    private var activeWorkspaceDragTableView: SidebarWorkspaceTableViewImpl?
    // Keep the containing drop views alive as well. A fast release can leave a
    // deferred reorder waiting for its target bridge after the representable is
    // dismantled; retaining only the table would lose that pending operation.
    private var activeWorkspaceDragContainerView: SidebarWorkspaceTableContainerView?
    private var activeWorkspaceDragSessionId: UUID?
    private var activeWorkspaceDragCapabilityValue: String?
    private var workspaceDragSourceCompletionReceived = false
    private var pendingWorkspaceDragSessionId: UUID?
    private var pendingWorkspaceDragWorkspaceId: UUID?
    private var hasPendingOrActiveWorkspaceDrag: Bool {
        isWorkspaceDragSourceActive
            || pendingWorkspaceDragSessionId != nil
            || activeWorkspaceDragContainerView?.reorderDropView.hasPendingDrop == true
    }
    private weak var unreadSource: SidebarUnreadModel?
    private var unreadSnapshot = SidebarUnreadSnapshot()
    private var appliedUnreadSnapshot = SidebarUnreadSnapshot()
    private var hasPendingContentRefresh = false
    private var unreadObservation: SidebarUnreadObservation?
    private var clipBoundsObserver: NSObjectProtocol?
    private var resizeDidEndObserver: NSObjectProtocol?
    /// Latest immutable input offered while an interactive resize owns this
    /// window. Already-applied rows stay authoritative until the real end signal.
    private var deferredInteractiveResizeApply: SidebarWorkspaceTableApplyInput?
    private lazy var mutationScheduler = SidebarWorkspaceTableMutationScheduler(
        applyFlush: { [weak self] in self?.flushApply($0) },
        viewportChangeFlush: { [weak self] in self?.flushViewportChange() },
        reloadFlush: { [weak self] in self?.containerView?.tableView.reloadData() },
        contentRefreshFlush: { [weak self] in self?.flushContentRefresh() }
    )
    private let rowHeightCache = SidebarWorkspaceTableRowHeightCache()
    private let dropTargetGeometry = SidebarWorkspaceTableDropTargetGeometryGate()

#if DEBUG
    var reconfigurationProbe: (() -> Void)?
    var dropTargetComputationProbe: (() -> Void)? {
        get { dropTargetGeometry.computationProbe }
        set { dropTargetGeometry.computationProbe = newValue }
    }
#endif

    deinit {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        if let resizeDidEndObserver {
            NotificationCenter.default.removeObserver(resizeDidEndObserver)
        }
        previewBailoutTask?.cancel()
    }
    func makeContainerView() -> SidebarWorkspaceTableContainerView {
        let container = SidebarWorkspaceTableContainerView()
        containerView = container

        let table = container.tableView
        table.workspaceController = self
        container.clipView.workspaceController = self
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        // .plain, not .fullWidth: fullWidth still insets cell frames by
        // ~6pt per side, which pushed the whole row (selection background
        // and content) 6pt inboard of the legacy sidebar's geometry. The
        // cell owns its own 6pt outer padding (rowOuterHorizontalPadding),
        // so the table must hand it the full row width.
        table.style = .plain
        table.backgroundColor = .clear
        table.enclosingScrollView?.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = false
        table.rowHeight = SidebarWorkspaceTableRowHeightCalculator().defaultWorkspaceHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.action = #selector(didClickTableRow)
        table.doubleAction = #selector(didDoubleClickTableRow)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // Workspace rows are a source only. Reorder/drop destinations live in
        // the dedicated overlay so AppKit cannot claim Mission Control or
        // other window-level drags while a stale pasteboard is present.
        table.setDraggingSourceOperationMask([], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = container.scrollView
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentInsets = NSEdgeInsets(
            top: SidebarWorkspaceScrollInsets.workspaceList.top
                + SidebarWorkspaceListMetrics.rowVerticalPadding,
            left: 0,
            bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                + SidebarWorkspaceListMetrics.rowVerticalPadding,
            right: 0
        )
        scrollView.applySidebarOverlayScrollerConfiguration()

        container.reorderDropView.registerForDraggedTypes([
            SidebarWorkspaceReorderDropOverlay.pasteboardType,
        ])
        dropTargetGeometry.attach(containerView: container)
        container.bonsplitDropView.targetBridge = dropTargetGeometry.bonsplitTargetBridge

        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewportDidChange()
            }
        }

        resizeDidEndObserver = NotificationCenter.default.addObserver(
            forName: .cmuxInteractiveGeometryResizeDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interactiveGeometryResizeDidEnd()
            }
        }

        return container
    }

    func dismantleContainerView(_ container: SidebarWorkspaceTableContainerView) {
        guard containerView === container else { return }
        let preserveNativeDragPresentation = hasPendingOrActiveWorkspaceDrag
        if preserveNativeDragPresentation, activeWorkspaceDragContainerView == nil {
            activeWorkspaceDragContainerView = container
            installDeferredDropLifecycle(on: container)
        }
        mutationScheduler.cancelPendingApplyAndViewport()
        deferredInteractiveResizeApply = nil
        deferredPumpHeightRowIds.removeAll(keepingCapacity: false)
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        widthRemeasureTask?.cancel()
        widthRemeasureTask = nil
        let postUpdateActions = detachLoadedCells()
        // A representable can be dismantled while AppKit still owns the native
        // drag session (fullscreen/display reconstruction). Keep the action
        // graph and table delegate alive until the terminal source callback.
        // Retire controller-painted indicators while the action graph is still
        // available; dropping `actions` first would silently skip the
        // authoritative clear callback during presentation teardown.
        clearWorkspaceDragPresentation()
        if !hasPendingOrActiveWorkspaceDrag {
            // A writer can be requested before AppKit creates a native
            // session. This controller owns no completion in that interval;
            // calling the generic action would be able to end a newer drag
            // owned by another source.
            pendingWorkspaceDragSessionId = nil
            pendingWorkspaceDragWorkspaceId = nil
            actions = nil
        }
        unreadObservation?.cancel()
        unreadObservation = nil
        unreadSource = nil
        unreadSnapshot = SidebarUnreadSnapshot()
        appliedUnreadSnapshot = SidebarUnreadSnapshot()
        hasPendingContentRefresh = false
        pumpHeightOverrides.removeAll(keepingCapacity: false)
        rows.removeAll(keepingCapacity: false)
        workspaceIds.removeAll(keepingCapacity: false)
        selectedScrollTargetWorkspaceId = nil
        hoveredRowId = nil
        contextMenuRowId = nil
        cancelSelectionIntent()
        if !preserveNativeDragPresentation {
            clearDropViewActions(in: container)
        }
        setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
        if !hasPendingOrActiveWorkspaceDrag {
            detachController(from: container.tableView)
        }
        container.clipView.workspaceController = nil
        containerView = nil
        mutationScheduler.stagePostUpdateActions(postUpdateActions)
    }

    /// Installs one unread subscription for the native table. Snapshot changes
    /// are projected directly into affected visible cells, bypassing SwiftUI's
    /// `VerticalTabsSidebar.body` and its O(workspaces) row construction.
    func setUnreadSource(_ source: SidebarUnreadModel) {
        guard unreadSource !== source else { return }
        unreadObservation?.cancel()
        unreadSource = source
        applyUnreadSnapshot(source.snapshot)
        unreadObservation = source.observeSummaryChanges(owner: self) { controller, snapshot in
            controller.applyUnreadSnapshot(snapshot)
        }
    }

    private func applyUnreadSnapshot(_ nextSnapshot: SidebarUnreadSnapshot) {
        unreadSnapshot = nextSnapshot
        guard isPresentationActive else { return }
        hasPendingContentRefresh = true
        mutationScheduler.stageContentRefresh()
    }

    /// Applies unread content only after any staged table snapshot has committed.
    private func flushContentRefresh() {
        guard hasPendingContentRefresh,
              isPresentationActive,
              let containerView,
              !TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: containerView.window)
        else { return }

        let width = currentColumnWidth()
        guard width > 0 else {
            mutationScheduler.stageViewportChange()
            return
        }
        if lastMeasuredWidth > 0, width != lastMeasuredWidth {
            mutationScheduler.stageViewportChange()
            return
        }

        hasPendingContentRefresh = false
        let previousSnapshot = appliedUnreadSnapshot
        let nextSnapshot = unreadSnapshot
        appliedUnreadSnapshot = nextSnapshot

        let candidateIds = Set(previousSnapshot.summaryByWorkspaceId.keys)
            .union(nextSnapshot.summaryByWorkspaceId.keys)
        let changedWorkspaceIds = Set(candidateIds.filter {
            previousSnapshot.summary(forWorkspaceId: $0)
                != nextSnapshot.summary(forWorkspaceId: $0)
        })
        guard !changedWorkspaceIds.isEmpty else { return }

        var changedRows = IndexSet()
        for row in rows.indices {
            let configuration = rows[row]
            guard !configuration.appKitUnreadDependencyWorkspaceIds.isDisjoint(
                with: changedWorkspaceIds
            ) else {
                continue
            }
            let updated = configuration.applyingUnreadSnapshot(nextSnapshot)
            guard !configuration.hasEquivalentContent(to: updated) else { continue }
            rows[row] = updated
            changedRows.insert(row)
        }
        guard !changedRows.isEmpty else { return }

        // A pump can have installed a height override for the old model. It
        // must not win over the fresh cache entry while this content change is
        // committed.
        for index in changedRows where rows.indices.contains(index) {
            pumpHeightOverrides.removeValue(forKey: rows[index].id)
        }
        let heightChanges = rowHeightCache.prepareRows(
            at: changedRows,
            in: rows,
            columnWidth: width
        )
        if lastMeasuredWidth == 0 {
            lastMeasuredWidth = width
        }
        // Re-note every changed row, not only rows whose cache height differs:
        // AppKit may have queried the old delegate answer before this pass.
        var rowsToNote = changedRows
        rowsToNote.formUnion(heightChanges)
        reconfigureAndNoteRowsWithoutAnimation(
            changedRows,
            rowsToNote,
            in: containerView.tableView
        )
    }

    func setPresentationActive(_ isActive: Bool, workspaceIds liveWorkspaceIds: [UUID]) {
        guard isPresentationActive != isActive else {
            if !isActive {
                pruneHiddenPresentation(retainingWorkspaceIds: liveWorkspaceIds)
            }
            return
        }
        isPresentationActive = isActive
        if isActive {
            if unreadSnapshot != appliedUnreadSnapshot {
                hasPendingContentRefresh = true
                mutationScheduler.stageContentRefresh()
            }
            mutationScheduler.stageViewportChange()
            return
        }
        mutationScheduler.cancelPendingApplyAndViewport()
        deferredInteractiveResizeApply = nil
        deferredPumpHeightRowIds.removeAll(keepingCapacity: true)
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        widthRemeasureTask?.cancel()
        widthRemeasureTask = nil
        suspendPresentation(retainingWorkspaceIds: liveWorkspaceIds)
    }

    private func pruneHiddenPresentation(retainingWorkspaceIds liveWorkspaceIds: [UUID]) {
        guard workspaceIds != liveWorkspaceIds else { return }
        workspaceIds = liveWorkspaceIds
        let liveIds = Set(liveWorkspaceIds)
        let previousRowIds = rows.map(\.id)
        rows = rows.filter { liveIds.contains($0.workspaceId) }
        rowHeightCache.suspendPresentation(retaining: Set(rows.map(\.id)))
        if previousRowIds != rows.map(\.id) {
            mutationScheduler.stageTableReload()
        }
    }

    private func suspendPresentation(retainingWorkspaceIds liveWorkspaceIds: [UUID]) {
        let liveIds = Set(liveWorkspaceIds)
        let previousRowIds = rows.map(\.id)
        let postUpdateActions = detachLoadedCells()
        rows = rows
            .filter { liveIds.contains($0.workspaceId) }
            .map { $0.presentationSnapshot() }
        // Retire controller-painted indicators while the action graph is still
        // available; dropping `actions` first would silently skip the
        // authoritative clear callback during presentation teardown.
        clearWorkspaceDragPresentation()
        if !hasPendingOrActiveWorkspaceDrag {
            // There is no table-owned native session to complete here. Leave
            // session termination to the native source instead of invoking a
            // generic callback during presentation teardown.
            pendingWorkspaceDragSessionId = nil
            pendingWorkspaceDragWorkspaceId = nil
            actions = nil
        }
        workspaceIds = liveWorkspaceIds
        selectedScrollTargetWorkspaceId = nil
        hoveredRowId = nil
        contextMenuRowId = nil
        optimisticallyPaintedRowIds.removeAll(keepingCapacity: true)
        pumpHeightOverrides.removeAll(keepingCapacity: true)
        cancelSelectionIntent()
        rowHeightCache.suspendPresentation(retaining: Set(rows.map(\.id)))
        if let containerView, !hasPendingOrActiveWorkspaceDrag {
            clearDropViewActions(in: containerView)
            if previousRowIds != rows.map(\.id) {
                mutationScheduler.stageTableReload()
            }
        } else if let containerView, previousRowIds != rows.map(\.id) {
            // A retained native source still owns the old drop callbacks. The
            // row snapshot may change while hidden, but clearing those callbacks
            // would erase a deferred drop before AppKit completes the source.
            mutationScheduler.stageTableReload()
        }
        setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
        mutationScheduler.stagePostUpdateActions(postUpdateActions)
    }

    private func detachLoadedCells() -> [@MainActor () -> Void] {
        var postUpdateActions: [@MainActor () -> Void] = []
        for cell in createdCellViews.allObjects {
            postUpdateActions.append(contentsOf: detachPresentation(from: cell, commitEdits: true))
        }
        return postUpdateActions
    }

    private func detachPresentation(
        from cell: NSView,
        commitEdits: Bool
    ) -> [@MainActor () -> Void] {
        switch cell {
        case let cell as SidebarWorkspaceRowTableCellView:
            return cell.detachPresentation(commitEdits: commitEdits)
        case let cell as SidebarGroupHeaderTableCellView:
            cell.suspendPresentation()
        case let cell as SidebarWorkspaceTableCellView:
            cell.clearRetainedPayload()
        default:
            break
        }
        return []
    }

    private func retirePresentation(
        from cell: NSView,
        commitEdits: Bool
    ) -> [@MainActor () -> Void] {
        if let cell = cell as? SidebarWorkspaceRowTableCellView {
            return cell.retirePresentation(commitEdits: commitEdits)
        }
        return detachPresentation(from: cell, commitEdits: commitEdits)
    }

    func apply(
        rows nextRows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds nextWorkspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?
    ) {
        guard isPresentationActive else { return }
        mutationScheduler.stageApply(
            SidebarWorkspaceTableApplyInput(
                rows: nextRows,
                actions: actions,
                workspaceIds: nextWorkspaceIds,
                selectedWorkspaceId: selectedWorkspaceId,
                selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
            )
        )
    }

    private func flushApply(_ input: SidebarWorkspaceTableApplyInput) {
        guard isPresentationActive, let containerView else { return }
        guard !TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(
            in: containerView.window
        ) else {
            deferredInteractiveResizeApply = input
            return
        }
        deferredInteractiveResizeApply = nil
        let nextRows = input.rows.map { $0.applyingUnreadSnapshot(unreadSnapshot) }
        appliedUnreadSnapshot = unreadSnapshot
        let actions = input.actions
        let nextWorkspaceIds = input.workspaceIds
        let selectedWorkspaceId = input.selectedWorkspaceId
        let selectedScrollTargetWorkspaceId = input.selectedScrollTargetWorkspaceId
        // Authoritative render: reconciles any optimistic preview, so the
        // preview bailout stands down.
        applyGeneration &+= 1
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        self.actions = actions
        actions.attachScrollView(containerView.scrollView)
        configureDropViews(in: containerView, actions: actions)
        if let retainedContainer = activeWorkspaceDragContainerView,
           retainedContainer !== containerView {
            // Rebind the retained drop views to the latest render/action graph
            // while AppKit keeps the old source alive through reconstruction.
            // The drop view owns any pending payload; rebinding must not clear it.
            configureDropViews(in: retainedContainer, actions: actions)
        }

        let previousRows = rows
        let hasStructuralChanges = previousRows.map(\.id) != nextRows.map(\.id)
        var contentChanges = IndexSet(nextRows.indices.filter { index in
            previousRows.indices.contains(index)
                && !previousRows[index].hasEquivalentContent(to: nextRows[index])
        })
        // Optimistically painted rows reconcile even when their model did
        // not change: the preview may not match the authoritative outcome,
        // and this apply cancels the bailout that would otherwise catch it.
        if !optimisticallyPaintedRowIds.isEmpty {
            for (index, row) in nextRows.enumerated()
            where optimisticallyPaintedRowIds.contains(row.id) {
                contentChanges.insert(index)
            }
            optimisticallyPaintedRowIds.removeAll(keepingCapacity: true)
        }
        let width = currentColumnWidth()
        var heightChanges = IndexSet()
        if width == lastMeasuredWidth || lastMeasuredWidth == 0 {
            // Reuse this apply's equivalence pass: indices outside
            // contentChanges are proven equivalent, so the cache skips its
            // own row-equality re-check for them (one O(n) equality pass per
            // apply instead of two). Only valid when ids didn't move.
            let provenUnchanged = hasStructuralChanges
                ? IndexSet()
                : IndexSet(nextRows.indices).subtracting(contentChanges)
            heightChanges = rowHeightCache.prepareHostedRows(
                nextRows,
                columnWidth: width,
                skippingEquivalenceCheckAt: provenUnchanged
            )
            if width > 0 { lastMeasuredWidth = width }
        } else {
            // Divider drag in flight: keep last-width heights (text truncates
            // live) and re-measure once the width settles.
            scheduleWidthRemeasure()
        }
        // Releasing a pump override changes what heightOfRow answers, so the
        // released rows must be re-noted like any other height change.
        // Clearing silently left the table on the override height while the
        // cache served the measured one — the row clipping/overlap reports
        // (probe: served=48 actual=50 on every streaming row).
        if !pumpHeightOverrides.isEmpty {
            for (index, row) in nextRows.enumerated() where pumpHeightOverrides[row.id] != nil {
                heightChanges.insert(index)
            }
        }
        pumpHeightOverrides.removeAll(keepingCapacity: true)

        var previousIds: [SidebarWorkspaceRenderItemID] = []
        var nextIds: [SidebarWorkspaceRenderItemID] = []
        var isSmallPureReorder = false
        if hasStructuralChanges {
            previousIds = previousRows.map(\.id)
            nextIds = nextRows.map(\.id)
            // Positional mismatches bound the number of moveRow calls a drag
            // needs (a single dragged row misaligns one contiguous span).
            // Multiset equality (not Set) so duplicate ids — corrupt state —
            // never masquerade as a pure reorder; and past the threshold the
            // move planner's rescans would go quadratic, so bulk permutations
            // take the reload path (they gain nothing from animation).
            let mismatches = zip(previousIds, nextIds).reduce(into: 0) { count, pair in
                if pair.0 != pair.1 { count += 1 }
            }
            isSmallPureReorder = previousIds.count == nextIds.count
                && mismatches <= Self.maxAnimatedReorderMoves
                && Self.multisetEqual(previousIds, nextIds)
        }
        let requiresAtomicReorderReload =
            hasStructuralChanges && !heightChanges.isEmpty && isSmallPureReorder
        let viewportAnchor = requiresAtomicReorderReload
            ? SidebarWorkspaceTableViewportAnchor.capture(
                table: containerView.tableView,
                previousRows: previousRows,
                nextRows: nextRows
            )
            : nil
        rows = nextRows

#if DEBUG
        if hasStructuralChanges || !contentChanges.isEmpty {
            cmuxDebugLog(
                "sidebar.table.apply structural=\(hasStructuralChanges ? 1 : 0) " +
                "contentChanges=\(contentChanges.count) rows=\(nextRows.count)"
            )
        }
#endif
        if hasStructuralChanges {
            if heightChanges.isEmpty, isSmallPureReorder {
                // Stable-geometry reorder (drag-drop): move rows in place.
                // reloadData tears down every visible cell and snaps the
                // scroll position, while moves keep cells alive and settle
                // smoothly. A reorder that also changes height must reload:
                // AppKit can otherwise reuse a moved cell at its old frame
                // before the separate height notification takes effect,
                // clipping checklist or notification content.
                let table = containerView.tableView
                performTableGeometryUpdateWithoutAnimation(in: table) {
                    table.beginUpdates()
                    var current = previousIds
                    for targetIndex in nextIds.indices where current[targetIndex] != nextIds[targetIndex] {
                        guard let fromIndex = current.firstIndex(of: nextIds[targetIndex]) else { continue }
                        table.moveRow(at: fromIndex, to: targetIndex)
                        current.remove(at: fromIndex)
                        current.insert(nextIds[targetIndex], at: targetIndex)
                    }
                    table.endUpdates()
                    // Per-index state (first-row flag, drop-indicator geometry)
                    // shifts with the order even when per-id content didn't.
                    let visible = table.rows(in: table.visibleRect)
                    if visible.length > 0 {
                        reconfigureVisibleRows(
                            IndexSet(integersIn: visible.lowerBound..<(visible.lowerBound + visible.length))
                        )
                    }
                }
            } else {
                let table = containerView.tableView
                // The atomic height-changing reorder path replaces visible
                // cells. Capture active rename/checklist drafts before AppKit
                // calls prepareForReuse, then commit them through the existing
                // post-update scheduler once the reload has settled.
                let postUpdateActions = requiresAtomicReorderReload
                    ? detachLoadedCells()
                    : []
                performTableGeometryUpdateWithoutAnimation(heightChanges, in: table) {
                    table.reloadData()
                    // A height-changing reorder needs the atomic reload above to
                    // avoid stale moved-row frames. Preserve a stable visible
                    // row's pixel offset so that correctness does not jump the viewport.
                    viewportAnchor?.restore(table: table, rows: nextRows)
                }
                mutationScheduler.stagePostUpdateActions(postUpdateActions)
            }
        } else {
            if !contentChanges.isEmpty || !heightChanges.isEmpty {
                var rowsToNote = heightChanges
                rowsToNote.formUnion(contentChanges)
                reconfigureAndNoteRowsWithoutAnimation(
                    contentChanges,
                    rowsToNote,
                    in: containerView.tableView
                )
            }
        }

#if DEBUG
        // Height-drift probe (row clipping reports): the height the cache
        // would serve vs the height the table is actually using. Any drift
        // means a noteHeightOfRows was missed for that row. rect(ofRow:)
        // includes intercellSpacing — subtract it or every row reports a
        // phantom constant drift.
        do {
            let table = containerView.tableView
            let spacing = table.intercellSpacing.height
            let probeWidth = lastMeasuredWidth > 0 ? lastMeasuredWidth : currentColumnWidth()
            let visible = table.rows(in: table.visibleRect)
            for row in visible.lowerBound..<(visible.lowerBound + visible.length)
            where rows.indices.contains(row) {
                let served = pumpHeightOverrides[rows[row].id]
                    ?? rowHeightCache.height(for: rows[row], columnWidth: probeWidth)
                    ?? rows[row].estimatedHeight
                let actual = table.rect(ofRow: row).height - spacing
                if abs(served - actual) > 0.5 {
                    cmuxDebugLog(
                        "sidebar.heightDrift row=\(row) served=\(served) actual=\(actual) width=\(probeWidth)"
                    )
                }
            }
        }
#endif

        let shouldScrollAfterWorkspaceChange = SidebarSelectedWorkspaceScrollPolicy
            .shouldScrollSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                oldWorkspaceIds: workspaceIds,
                newWorkspaceIds: nextWorkspaceIds
            )
        workspaceIds = nextWorkspaceIds
        let selectionTargetChanged = self.selectedScrollTargetWorkspaceId != selectedScrollTargetWorkspaceId
        self.selectedScrollTargetWorkspaceId = selectedScrollTargetWorkspaceId
        // A drop in this window must not move the viewport: the pointer's
        // release position IS the user's context. The selected-scroll policy
        // cannot tell a local drag reorder from an external index change, so
        // the drop arms a one-shot suppression consumed by this apply.
        let suppressForLocalDrop = suppressSelectedScrollAfterLocalDrop
        suppressSelectedScrollAfterLocalDrop = false
        if !suppressForLocalDrop, selectionTargetChanged || shouldScrollAfterWorkspaceChange {
            scrollSelectedRowToVisibleIfNeeded()
        }
        synchronizeAppKitDropIndicator(actions: actions)
        recomputeHoveredRow()
        enforceHoverOnVisibleCells()
        updateDropTargets()
        replanReorderDragIfActive()
        if hasPendingContentRefresh, width > 0, width == lastMeasuredWidth {
            mutationScheduler.stageContentRefresh()
        }
        replayDeferredRowClickIfPossible()
    }

    private func interactiveGeometryResizeDidEnd() {
        guard let containerView,
              !TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(
                  in: containerView.window
              ) else {
            return
        }
        if let deferredInteractiveResizeApply {
            self.deferredInteractiveResizeApply = nil
            mutationScheduler.stageApply(deferredInteractiveResizeApply)
        }
        performWidthRemeasureNow()
    }

    /// Row clicks route through the table's action (NSTableView owns the
    /// mouse tracking loop, so cell-level gesture recognizers never fire).
    @objc private func didClickTableRow() {
        guard let table = containerView?.tableView else { return }
        let row = table.clickedRow
#if DEBUG
        cmuxDebugLog("sidebar.table.click row=\(row) rows=\(rows.count)")
#endif
        guard rows.indices.contains(row) else { return }
        // Capture modifiers from the clicking EVENT at action time: a
        // deferred or coalesced apply must not re-read the keyboard later,
        // and the global NSEvent.modifierFlags reads hardware state, which
        // misses event-carried flags (synthetic clicks, exotic input methods).
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let click = DeferredRowClick(rowId: rows[row].id, modifiers: modifiers)
        switch dispatchRowClick(click) {
        case .dispatched:
            deferredRowClick = nil
        case .awaitingActions:
            // Presentation snapshots intentionally release their live action
            // captures while hidden. The retained row can become visible
            // before SwiftUI supplies its first authoritative reveal apply,
            // so preserve the completed click by stable row identity.
            previewSelection(row: row, modifiers: modifiers, hitView: nil)
            deferredRowClick = click
            // Request the apply the replay depends on. Fired only from a
            // physical click (never from a replay re-park), so a request per
            // click is the ceiling and a pathological apply cannot loop.
#if DEBUG
            cmuxDebugLog("sidebar.table.applyRequest row=\(row)")
#endif
            onDeferredRowClickAwaitingApply?()
        case .invalid:
            deferredRowClick = nil
        }
    }

    private func dispatchRowClick(_ click: DeferredRowClick) -> RowClickDispatchOutcome {
        guard let row = rows.firstIndex(where: { $0.id == click.rowId }) else {
            return .invalid
        }
        let configuration = rows[row]
        if let actions = configuration.appKitWorkspaceRowActions {
            previewSelection(row: row, modifiers: click.modifiers, hitView: nil)
            dispatchSelection(modifiers: click.modifiers) {
                actions.commands.updateSelection(modifiers: click.modifiers)
            }
            return .dispatched
        }
        if let headerActions = configuration.appKitGroupHeaderActions {
            previewSelection(row: row, modifiers: click.modifiers, hitView: nil)
            dispatchSelection(modifiers: click.modifiers) {
                headerActions.onFocusAnchor(click.modifiers)
            }
            return .dispatched
        }
        if configuration.appKitWorkspaceRowModel != nil
            || configuration.appKitGroupHeaderModel != nil {
            return .awaitingActions
        }
        return .invalid
    }

    private func dispatchSelection(
        modifiers: NSEvent.ModifierFlags,
        action: @escaping @MainActor () -> Void
    ) {
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            // Multi-select mutations are order-dependent and extend the
            // selection the user currently sees: flush (not drop) a plain
            // click still in the coalescing window first.
            selectionCoalescer.flushNow()
            action()
        } else {
            selectionCoalescer.request(action)
        }
    }

    private func replayDeferredRowClickIfPossible() {
        guard let click = deferredRowClick else { return }
        deferredRowClick = nil
        if case .awaitingActions = dispatchRowClick(click) {
            deferredRowClick = click
        }
    }

    private func cancelSelectionIntent() {
        deferredRowClick = nil
        selectionCoalescer.cancel()
    }

    @objc private func didDoubleClickTableRow() {
        guard let table = containerView?.tableView else { return }
        let row = table.clickedRow
#if DEBUG
        cmuxDebugLog("sidebar.table.doubleClick row=\(row) rows=\(rows.count)")
#endif
        guard rows.indices.contains(row),
              rows[row].appKitWorkspaceRowModel != nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView else { return }
        // The single-click action fires for both clicks of a double-click, so
        // click 2 has a trailing selection application queued. Letting it land
        // after the rename field takes the field editor re-activates the
        // workspace, which pulls first responder back to the terminal and
        // end-editing commits the untouched title — the field flashes and
        // vanishes. A double-click is a rename gesture: drop the queued
        // selection before starting the edit.
        cancelSelectionIntent()
        cell.beginInlineRename()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return tableView.rowHeight }
        let configuration = rows[row]
        if let override = pumpHeightOverrides[configuration.id] {
            return override
        }
        let columnWidth = lastMeasuredWidth > 0 ? lastMeasuredWidth : currentColumnWidth()
        return rowHeightCache.height(
            for: configuration,
            columnWidth: columnWidth
        ) ?? configuration.estimatedHeight
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if rows[row].appKitGroupHeaderModel != nil {
            let cell = tableView.makeView(
                withIdentifier: SidebarGroupHeaderTableCellView.reuseIdentifier,
                owner: self
            ) as? SidebarGroupHeaderTableCellView ?? SidebarGroupHeaderTableCellView()
            createdCellViews.add(cell)
            configure(headerCell: cell, at: row)
            return cell
        }
        if rows[row].appKitWorkspaceRowModel != nil {
            let cell = tableView.makeView(
                withIdentifier: SidebarWorkspaceRowTableCellView.reuseIdentifier,
                owner: self
            ) as? SidebarWorkspaceRowTableCellView ?? SidebarWorkspaceRowTableCellView()
            createdCellViews.add(cell)
            configure(workspaceCell: cell, at: row)
            return cell
        }
        let cell = tableView.makeView(
            withIdentifier: SidebarWorkspaceTableCellView.reuseIdentifier,
            owner: self
        ) as? SidebarWorkspaceTableCellView ?? SidebarWorkspaceTableCellView()
        createdCellViews.add(cell)
        configure(cell: cell, at: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? NSView else { return }
        // Row retirement is the authoritative cleanup signal. A temporary
        // whole-table window reparent leaves its row views installed, while
        // an actual deletion/reload removes them through this callback.
        let postUpdateActions = retirePresentation(from: cell, commitEdits: true)
        mutationScheduler.stagePostUpdateActions(postUpdateActions)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // Group headers intentionally mint their anchor payload: anchor drags
        // route to top-level whole-group plans and are rejected cross-window.
        _ = tableView
        guard rows.indices.contains(row), let actions else { return nil }
        let rowConfiguration = rows[row]
        let workspaceId = actions.workspaceIdForDrag?(
            rowConfiguration.id,
            rowConfiguration.workspaceId
        ) ?? rowConfiguration.workspaceId
        if pendingWorkspaceDragWorkspaceId == nil {
            // AppKit asks for the writer before it creates an NSDraggingSession.
            // Keep only the row identity here; the live coordinator session is
            // created in `willBeginAt`, so a writer that is abandoned during a
            // reconstruction cannot leave a dead registry entry behind.
            pendingWorkspaceDragWorkspaceId = workspaceId
        }
        let payloadWorkspaceId = pendingWorkspaceDragWorkspaceId ?? workspaceId
        return SidebarTabDragPayload(
            tabId: payloadWorkspaceId,
            sessionId: pendingWorkspaceDragSessionId
        ).pasteboardItem()
    }

    /// Retains the table/controller pair once AppKit has created the native
    /// session. This keeps the delegate alive through fullscreen/display
    /// reconstruction until AppKit's terminal callback.
    private func retainWorkspaceDragSource(_ tableView: NSTableView) {
        guard let tableView = tableView as? SidebarWorkspaceTableViewImpl else { return }
        activeWorkspaceDragTableView = tableView
        tableView.activeWorkspaceDragController = self
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        _ = screenPoint
        let draggedRows = Array(rowIndexes)
        if let sourceRow = draggedRows.first, rows.indices.contains(sourceRow) {
            let rowConfiguration = rows[sourceRow]
            let workspaceId = actions?.workspaceIdForDrag?(
                rowConfiguration.id,
                rowConfiguration.workspaceId
            ) ?? rowConfiguration.workspaceId
            let currentSessionId = actions?.nativeWorkspaceDragLifecycle?.currentSessionId()
            if pendingWorkspaceDragSessionId == nil || pendingWorkspaceDragSessionId != currentSessionId {
                actions?.beginWorkspaceDrag(workspaceId)
                pendingWorkspaceDragSessionId = actions?.nativeWorkspaceDragLifecycle?.currentSessionId()
                pendingWorkspaceDragWorkspaceId = workspaceId
            }
            let payloadWorkspaceId = pendingWorkspaceDragWorkspaceId ?? workspaceId
            activeWorkspaceDragSessionId = pendingWorkspaceDragSessionId
            if let activeWorkspaceDragSessionId {
                let capabilityValue = SidebarTabDragPayload(
                    tabId: payloadWorkspaceId,
                    sessionId: activeWorkspaceDragSessionId
                ).pasteboardValue
                activeWorkspaceDragCapabilityValue = capabilityValue
                // The writer runs before AppKit creates the session. Re-write
                // the live pasteboard here so the terminal callback can fence
                // cleanup against a newer drag of the same workspace.
                session.draggingPasteboard.setString(
                    capabilityValue,
                    forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
                )
            }
            workspaceDragSessionDidBegin()
        }
        session.enumerateDraggingItems(
            options: [],
            for: tableView,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { [self] draggingItem, itemIndex, _ in
            guard draggedRows.indices.contains(itemIndex) else { return }
            let row = draggedRows[itemIndex]
            guard rows.indices.contains(row) else { return }
            let rowConfiguration = rows[row]
            let workspaceId = actions?.workspaceIdForDrag?(
                rowConfiguration.id,
                rowConfiguration.workspaceId
            ) ?? rowConfiguration.workspaceId
            let count = actions?.movingWorkspaceCount?(workspaceId) ?? 1
            guard count > 1,
                  let image = workspaceDragImage(
                      tableView: tableView,
                      row: row,
                      size: draggingItem.draggingFrame.size,
                      count: count
                  ) else {
                return
            }
            draggingItem.setDraggingFrame(draggingItem.draggingFrame, contents: image)
        }
    }

    private func workspaceDragImage(
        tableView: NSTableView,
        row: Int,
        size: NSSize,
        count: Int
    ) -> NSImage? {
        let rowRect = tableView.rect(ofRow: row)
        guard rowRect.width > 0,
              rowRect.height > 0,
              size.width > 0,
              size.height > 0,
              let representation = tableView.bitmapImageRepForCachingDisplay(in: rowRect) else {
            return nil
        }
        tableView.cacheDisplay(in: rowRect, to: representation)
        let rowImage = NSImage(size: rowRect.size)
        rowImage.addRepresentation(representation)

        return NSImage(size: size, flipped: false) { bounds in
            rowImage.draw(in: bounds)

            let badgeDiameter: CGFloat = 18
            let badgeInset: CGFloat = 2
            let badgeRect = NSRect(
                x: bounds.maxX - badgeDiameter - badgeInset,
                y: bounds.maxY - badgeDiameter - badgeInset,
                width: badgeDiameter,
                height: badgeDiameter
            )
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let countText = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = countText.size(withAttributes: attributes)
            countText.draw(
                at: NSPoint(
                    x: badgeRect.midX - (textSize.width / 2),
                    y: badgeRect.midY - (textSize.height / 2)
                ),
                withAttributes: attributes
            )
            return true
        }
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        workspaceDragSessionDidEnd()
    }

    func workspaceDragSessionDidBegin() {
        guard !isWorkspaceDragSourceActive else { return }
        if workspaceDragSourceCompletionReceived,
           let retainedContainer = activeWorkspaceDragContainerView {
            // A deferred drop from the previous native source cannot survive
            // a newer source. Invalidate it before replacing the retained
            // container, otherwise its late target update would either leak
            // the old graph or commit against the new drag.
            retainedContainer.reorderDropView.invalidatePendingDropForNewNativeSession()
            releaseRetainedWorkspaceDragContainerIfPossible()
        }
        isWorkspaceDragSourceActive = true
        workspaceDragSourceCompletionReceived = false
        if let containerView {
            activeWorkspaceDragContainerView = containerView
            retainWorkspaceDragSource(containerView.tableView)
            installDeferredDropLifecycle(on: containerView)
        }
        // A drag consumes the press: the click action never fires, so no
        // authoritative selection apply will reconcile the optimistic press
        // highlight painted in previewSelection — without this rollback a
        // fast drag leaves the grabbed row painted selected and every other
        // visible row peeled. Drop the queued selection and restore visible
        // cells from their stored models before drop targets paint.
        cancelSelectionIntent()
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        restoreVisibleCellPaint()
    }

    /// Drops a provisional writer identity before a new mouse gesture. A
    /// writer can be requested before AppKit creates a native session; if that
    /// gesture is abandoned, the next press must not reuse its workspace id.
    func prepareForMouseDown() {
        guard !isWorkspaceDragSourceActive else { return }
        pendingWorkspaceDragSessionId = nil
        pendingWorkspaceDragWorkspaceId = nil
    }

    func workspaceDragSessionDidEnd() {
        // AppKit may deliver a duplicate terminal callback while a deferred
        // drop is still waiting for its target bridge. The first callback owns
        // source completion; a later callback must not fall back to the
        // unscoped compatibility end hook (which could end a newer session).
        if !isWorkspaceDragSourceActive,
           activeWorkspaceDragSessionId == nil,
           pendingWorkspaceDragSessionId == nil {
            clearWorkspaceDragPresentation()
            releaseRetainedWorkspaceDragContainerIfPossible()
            return
        }
        guard hasPendingOrActiveWorkspaceDrag else {
            clearWorkspaceDragPresentation()
            pendingWorkspaceDragSessionId = nil
            return
        }
        isWorkspaceDragSourceActive = false
        let sessionId = activeWorkspaceDragSessionId ?? pendingWorkspaceDragSessionId
        let capabilityValue = activeWorkspaceDragCapabilityValue ?? {
            guard let sessionId,
                  let workspaceId = pendingWorkspaceDragWorkspaceId else { return nil }
            return SidebarTabDragPayload(
                tabId: workspaceId,
                sessionId: sessionId
            ).pasteboardValue
        }()
        if let nativeWorkspaceDragLifecycle = actions?.nativeWorkspaceDragLifecycle {
            // A tokenized bundle owns completion. If AppKit omitted either
            // value, leave the registry untouched rather than invoking a
            // legacy unscoped end callback.
            if let sessionId, let capabilityValue {
                nativeWorkspaceDragLifecycle.finish(sessionId, capabilityValue)
            }
        } else {
            actions?.endWorkspaceDrag()
        }
        activeWorkspaceDragSessionId = nil
        activeWorkspaceDragCapabilityValue = nil
        pendingWorkspaceDragSessionId = nil
        pendingWorkspaceDragWorkspaceId = nil
        reorderDragWindowPoint = nil
        reorderDragPayloadWorkspaceId = nil
        retireReorderIndicator()

        let tableView = activeWorkspaceDragTableView
        activeWorkspaceDragTableView = nil
        workspaceDragSourceCompletionReceived = true
        tableView?.activeWorkspaceDragController = nil
        if let tableView, tableView !== containerView?.tableView {
            detachController(from: tableView)
        }
        releaseRetainedWorkspaceDragContainerIfPossible()
        if !isPresentationActive || containerView == nil {
            actions = nil
        }
    }

    private func installDeferredDropLifecycle(on container: SidebarWorkspaceTableContainerView) {
        container.reorderDropView.onPendingDropLifecycleEnded = { [weak self, weak container] in
            guard let self, let container else { return }
            self.releaseRetainedWorkspaceDragContainerIfPossible(container: container)
        }
    }

    private func releaseRetainedWorkspaceDragContainerIfPossible(
        container expectedContainer: SidebarWorkspaceTableContainerView? = nil
    ) {
        guard workspaceDragSourceCompletionReceived,
              let retainedContainer = activeWorkspaceDragContainerView,
              expectedContainer == nil || retainedContainer === expectedContainer,
              !retainedContainer.reorderDropView.hasPendingDrop else {
            return
        }
        if retainedContainer !== containerView {
            clearDropViewActions(in: retainedContainer)
        } else {
            retainedContainer.reorderDropView.onPendingDropLifecycleEnded = nil
        }
        activeWorkspaceDragContainerView = nil
        workspaceDragSourceCompletionReceived = false
    }

    private func clearWorkspaceDragPresentation() {
        reorderDragWindowPoint = nil
        reorderDragPayloadWorkspaceId = nil
        retireReorderIndicator()
    }

    private func detachController(from tableView: SidebarWorkspaceTableViewImpl) {
        tableView.workspaceController = nil
        tableView.dataSource = nil
        tableView.delegate = nil
    }

    // MARK: Workspace reorder drop

    /// Window-space location of the live reorder drag. Present only between
    /// an accepted overlay update and the drop/exit/end that retires it; while
    /// present, every viewport change re-plans against it so the indicator
    /// tracks rows sliding under a stationary pointer during edge autoscroll.
    private var reorderDragWindowPoint: NSPoint?

    /// Controller-owned indicator paint for the live reorder drag. The plan
    /// result deliberately never enters the SwiftUI drag state (that rebuilds
    /// every sidebar row per gap change and made the line lag the pointer);
    /// the controller paints the affected cells directly instead.
    private var reorderIndicatorPainter: SidebarWorkspaceTableReorderIndicatorPainter?

    /// Workspace id parsed from the live drag pasteboard by the overlay.
    /// Confirms the coordinator session during reconstruction; it cannot create
    /// a session when the native source has already completed.
    private var reorderDragPayloadWorkspaceId: UUID?

    /// The plan whose indicator is currently painted. The drop commits this
    /// plan verbatim so the outcome always matches the line the user saw;
    /// re-resolving at release time could pick a different gap (pointer
    /// drift after the last drag update, or an autoscroll tick landing
    /// before the coalesced repaint).
    private var lastAcceptedReorderDropPlan: SidebarWorkspaceReorderDropPlan?

    /// One-shot: the next apply comes from this window's own drop, so the
    /// selected-workspace scroll policy must not yank the viewport away from
    /// the release position.
    private var suppressSelectedScrollAfterLocalDrop = false

    private func performReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        payloadWorkspaceId: UUID?
    ) -> Bool {
        reorderDragWindowPoint = nil
        guard let actions else {
            retireReorderIndicator()
            return false
        }
        let performed: Bool
        let commitSource: String
        if let plan = lastAcceptedReorderDropPlan {
            // Commit exactly what the indicator showed.
            performed = actions.commitWorkspaceDropPlan(plan)
            commitSource = "paintedPlan"
        } else {
            // No accepted hover plan exists: resolve from the release point.
            performed = actions.performWorkspaceDrop(point, targets, payloadWorkspaceId)
            commitSource = "releasePoint"
        }
#if DEBUG
        // Every silent "the workspace I dragged didn't move" report needs
        // this line: where the drop landed, which commit source ran, and
        // whether the shared planner accepted it.
        cmuxDebugLog(
            "sidebar.drop.perform point=(\(Int(point.x)),\(Int(point.y))) " +
            "source=\(commitSource) performed=\(performed ? 1 : 0)"
        )
#endif
        if performed {
            suppressSelectedScrollAfterLocalDrop = true
        }
        retireReorderIndicator()
        return performed
    }

    func reorderDropDragExited() {
        reorderDragPayloadWorkspaceId = nil
        guard reorderDragWindowPoint != nil || reorderIndicatorPainter != nil else { return }
        reorderDragWindowPoint = nil
        retireReorderIndicator()
    }

    /// Runs the shared reorder planner for a drag hovering at `windowPoint`
    /// and paints the resulting indicator. An accepted position is remembered
    /// (window space) so viewport changes can re-plan it; a rejected one
    /// stops the re-plan loop until the pointer produces a new overlay update.
    @discardableResult
    func updateReorderDrag(windowPoint: NSPoint) -> Bool {
        guard let dropView = containerView?.reorderDropView else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
            return false
        }
        let targets = refreshReorderDropTargets()
        return updateReorderDrag(
            point: dropView.convert(windowPoint, from: nil),
            targets: targets,
            windowPoint: windowPoint,
            payloadWorkspaceId: reorderDragPayloadWorkspaceId
        )
    }

    private func updateReorderDrag(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        windowPoint: NSPoint,
        payloadWorkspaceId: UUID?
    ) -> Bool {
        guard let actions else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
            return false
        }
        reorderDragPayloadWorkspaceId = payloadWorkspaceId
        guard !targets.isEmpty,
              let update = actions.updateWorkspaceDrag(
                  point,
                  targets,
                  payloadWorkspaceId
              )
        else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
            return false
        }
        reorderIndicatorPainter = SidebarWorkspaceTableReorderIndicatorPainter(
            indicator: update.indicator,
            scope: update.scope,
            draggedWorkspaceId: update.draggedWorkspaceId,
            indicatorRowIds: update.indicatorRowIds
        )
        lastAcceptedReorderDropPlan = update.plan
        enforceReorderIndicatorPaintOnVisibleCells()
        setAppKitDropIndicator(update.indicator, scope: update.scope, includeRowTargets: false)
        reorderDragWindowPoint = windowPoint
        return true
    }

    private func retireReorderIndicator() {
        lastAcceptedReorderDropPlan = nil
        guard reorderIndicatorPainter != nil else { return }
        reorderIndicatorPainter = nil
        clearReorderIndicatorPaintOnVisibleCells()
        actions?.clearWorkspaceDropIndicator()
        setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
    }

    private func enforceReorderIndicatorPaintOnVisibleCells() {
        guard reorderIndicatorPainter != nil else { return }
        sweepReorderIndicatorPaint(reorderIndicatorPainter)
    }

    private func clearReorderIndicatorPaintOnVisibleCells() {
        sweepReorderIndicatorPaint(nil)
    }

    /// A nil painter clears every visible drop line, which is only safe here
    /// because reorder and bonsplit drags cannot overlap: outside a reorder
    /// drag the row models carry `false` for both flags, so clearing matches
    /// what the next configure would apply anyway.
    private func sweepReorderIndicatorPaint(
        _ painter: SidebarWorkspaceTableReorderIndicatorPainter?
    ) {
        guard let table = containerView?.tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<(visible.lowerBound + visible.length)
        where rows.indices.contains(row) {
            let paint = painter?.paint(forRowWorkspaceId: rows[row].workspaceId)
                ?? (top: false, bottom: false)
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarWorkspaceRowTableCellView:
                cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
            case let cell as SidebarGroupHeaderTableCellView:
                cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
            default:
                break
            }
        }
    }

    /// Refreshes visible-row targets in the overlay's coordinate space.
    @discardableResult
    private func refreshReorderDropTargets() -> [SidebarWorkspaceReorderDropOverlay.Target] {
        guard let container = containerView else { return [] }
        let table = container.tableView
        let visibleRange = table.rows(in: table.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
            clearReorderDropTargets()
            return []
        }
        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        guard lower < upper else {
            clearReorderDropTargets()
            return []
        }
        let targets = (lower..<upper).map { row in
            let configuration = rows[row]
            return SidebarWorkspaceReorderDropOverlay.Target(
                workspaceId: configuration.workspaceId,
                groupId: configuration.groupId,
                isGroupHeader: configuration.isGroupHeader,
                frame: table.convert(table.rect(ofRow: row), to: container.reorderDropView)
            )
        }
        container.reorderDropView.targets = targets
        container.reorderDropView.targetsDidUpdate()
        return targets
    }

    private func clearReorderDropTargets() {
        guard let reorderDropView = containerView?.reorderDropView else { return }
        reorderDropView.targets = []
        reorderDropView.targetsDidUpdate()
    }

    /// Item-provider drag sources promise data rather than strings, so fall
    /// back to a UTF-8 decode of the raw data when `string(forType:)` is nil.
    private static func reorderPayloadWorkspaceId(_ pasteboard: NSPasteboard) -> UUID? {
        let type = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        let raw = pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
        let parsed = SidebarTabDragPayload.workspaceId(fromPasteboardString: raw)
#if DEBUG
        cmuxDebugLog(
            "sidebar.drop.payload raw=\(raw.map { String($0.prefix(24)) } ?? "nil") " +
            "parsed=\(parsed.map { String($0.uuidString.prefix(5)) } ?? "nil")"
        )
#endif
        return parsed
    }

    /// Optimistic press highlight: paints the clicked workspace cell as
    /// selected immediately and, for a plain click, peels the highlight off
    /// the outgoing rows so old and new selection never show together while
    /// the authoritative render is queued behind the terminal-view swap.
    /// The authoritative apply reconciles right after.
    func previewSelection(row: Int, modifiers: NSEvent.ModifierFlags, hitView: NSView?) {
        guard rows.indices.contains(row),
              let table = containerView?.tableView else { return }
        let workspaceCell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarWorkspaceRowTableCellView
        let headerCell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarGroupHeaderTableCellView
        if rows[row].appKitWorkspaceRowModel != nil {
            guard let workspaceCell else { return }
            if let hitView, workspaceCell.selectionPreviewShouldIgnore(hitView) { return }
        } else if rows[row].appKitGroupHeaderModel != nil {
            guard let headerCell else { return }
            if let hitView, headerCell.selectionPreviewShouldIgnore(hitView) { return }
        } else {
            return
        }
        let extendsSelection = modifiers.contains(.command) || modifiers.contains(.shift)
        if !extendsSelection {
            let visibleRows = table.rows(in: table.visibleRect)
            for visibleRow in visibleRows.lowerBound..<(visibleRows.lowerBound + visibleRows.length)
            where visibleRow != row {
                let cellView = table.view(atColumn: 0, row: visibleRow, makeIfNecessary: false)
                (cellView as? SidebarWorkspaceRowTableCellView)?.showOptimisticDeselection()
                (cellView as? SidebarGroupHeaderTableCellView)?.showOptimisticDeselection()
                if rows.indices.contains(visibleRow) {
                    optimisticallyPaintedRowIds.insert(rows[visibleRow].id)
                }
            }
            workspaceCell?.showOptimisticSelectionHighlight()
        } else {
            // A modifier click joins the multi-selection: preview the dim
            // multi-select tint, not the full active treatment (which made
            // every cmd-click flash bright and settle dim).
            workspaceCell?.showOptimisticMultiSelection()
        }
        if extendsSelection {
            headerCell?.showOptimisticMultiSelection()
        } else {
            headerCell?.showOptimisticAnchorActive()
        }
        optimisticallyPaintedRowIds.insert(rows[row].id)
        // Optimistic paint is only reconciled by an authoritative apply, and
        // some presses never produce one (drag that lands where it started,
        // press swallowed by the drag threshold, selection unchanged). Left
        // alone, those strand the peel — the sidebar shows NO selection until
        // an unrelated change repaints. Restore truth if no apply arrives.
        schedulePreviewBailout()
    }

    /// A user drag misaligns one contiguous span (single-digit moves); past
    /// this, the per-move array rescans trend quadratic and the reload path
    /// is both cheaper and visually equivalent for bulk permutations.
    private static let maxAnimatedReorderMoves = 32

    private static func multisetEqual(
        _ a: [SidebarWorkspaceRenderItemID],
        _ b: [SidebarWorkspaceRenderItemID]
    ) -> Bool {
        guard a.count == b.count else { return false }
        var counts: [SidebarWorkspaceRenderItemID: Int] = [:]
        counts.reserveCapacity(a.count)
        for id in a { counts[id, default: 0] += 1 }
        for id in b {
            guard let count = counts[id], count > 0 else { return false }
            counts[id] = count - 1
        }
        return true
    }

    private var applyGeneration: UInt64 = 0
    private var previewBailoutTask: Task<Void, Never>?
    private let previewBailoutClock = ContinuousClock()
    /// Rows whose cells carry optimistic paint. apply()'s reconcile diff only
    /// reconfigures rows whose MODEL changed, and a preview on a row whose
    /// authoritative state ends up unchanged (modifier mismatch, replaced
    /// preview) would otherwise keep its speculative paint forever — the
    /// apply cancels the bailout believing it reconciled.
    private var optimisticallyPaintedRowIds: Set<SidebarWorkspaceRenderItemID> = []

    private func schedulePreviewBailout() {
        previewBailoutTask?.cancel()
        let generation = applyGeneration
        // Injected-Clock sleep with cancellation (bounded-delay policy); the
        // authoritative apply cancels it and bumps the generation.
        previewBailoutTask = Task { [weak self, previewBailoutClock] in
            try? await previewBailoutClock.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.applyGeneration == generation else { return }
            self.previewBailoutTask = nil
            self.restoreVisibleCellPaint()
        }
    }

    private func restoreVisibleCellPaint() {
        guard let table = containerView?.tableView else { return }
        optimisticallyPaintedRowIds.removeAll(keepingCapacity: true)
        let visible = table.rows(in: table.visibleRect)
        for row in visible.lowerBound..<(visible.lowerBound + visible.length) {
            let cellView = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            (cellView as? SidebarWorkspaceRowTableCellView)?.restoreStoredModelPaint()
            (cellView as? SidebarGroupHeaderTableCellView)?.restoreStoredModelPaint()
        }
    }

    func middleClick(row: Int) {
        // Middle-click-close is a workspace-row gesture. A group header is not a
        // workspace row (it carries its anchor's workspaceId only for focus), so
        // it is excluded here just as the SwiftUI sidebar accepts only .workspace
        // rows. Group lifecycle runs through the header's own menu (Ungroup /
        // Delete Group), not a middle-click on the header.
        guard rows.indices.contains(row), !rows[row].isGroupHeader else { return }
        actions?.closeWorkspace(rows[row].workspaceId)
    }

    func doubleClickEmptyArea() {
        actions?.createWorkspaceAtEnd()
    }

    func createEmptyWorkspaceGroup() {
        actions?.createEmptyWorkspaceGroup()
    }

    func emptyAreaMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            ),
            action: #selector(createEmptyWorkspaceGroupFromMenu),
            keyEquivalent: ""
        )
        item.target = self
        let shortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
        if let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        menu.addItem(item)
        return menu
    }

    @objc private func createEmptyWorkspaceGroupFromMenu() {
        createEmptyWorkspaceGroup()
    }

    func pointerDidLeaveTable() {
        guard contextMenuRowId == nil else { return }
        setHoveredRowId(nil)
    }

    func recomputeHoveredRow() {
        guard contextMenuRowId == nil,
              let table = containerView?.tableView else {
            return
        }
        let row = SidebarWorkspaceTableHoverResolver().hoveredRow(
            windowPoint: table.lastPointerWindowLocation,
            convertToTable: { table.convert($0, from: nil) },
            rowAtPoint: { table.row(at: $0) },
            rowCount: rows.count
        )
        setHoveredRowId(row.map { rows[$0].id })
    }

    func viewportDidChange() {
        guard isPresentationActive else { return }
        mutationScheduler.stageViewportChange()
    }

    private func flushViewportChange() {
        guard isPresentationActive else { return }
        let width = currentColumnWidth()
#if DEBUG
        if width != lastMeasuredWidth {
            cmuxDebugLog("sidebar.viewport width=\(width) lastMeasured=\(lastMeasuredWidth)")
        }
#endif
        if width > 0, width != lastMeasuredWidth {
            performLiveWidthRemeasure(width: width)
            scheduleWidthRemeasure()
        }
        recomputeHoveredRow()
        enforceHoverOnVisibleCells()
        updateDropTargets()
        replanReorderDragIfActive()
    }

    /// Edge autoscroll moves rows under a stationary pointer, and AppKit only
    /// re-validates the drop when the pointer itself moves. Re-running the
    /// planner from the stored window point on every viewport change keeps
    /// the drop target (not just the indicator's pixels) tracking the rows.
    private func replanReorderDragIfActive() {
        guard let windowPoint = reorderDragWindowPoint else { return }
        updateReorderDrag(windowPoint: windowPoint)
    }

    private let selectionCoalescer = SidebarSelectionCoalescer<ContinuousClock>()
    private var lastMeasuredWidth: CGFloat = 0
    private var widthRemeasureTask: Task<Void, Never>?
    private var lastLiveMeasuredWidth: CGFloat = 0
    private var hasLiveMeasuredRows = false

    /// Legacy parity: rows re-wrap continuously while the divider or window
    /// edge is dragged instead of keeping last-width heights until mouse-up.
    /// Only the visible pure-AppKit rows (plus a small buffer) re-measure per
    /// width tick — manual frame math, no hosted SwiftUI layout — so the
    /// per-tick cost stays bounded regardless of total row count. Off-screen
    /// and hosted rows settle in the full pass at drag end.
    private func performLiveWidthRemeasure(width: CGFloat) {
        guard floor(width) != floor(lastLiveMeasuredWidth) else { return }
        guard let table = containerView?.tableView else {
#if DEBUG
            cmuxDebugLog("sidebar.liveReflow.skip reason=noTable width=\(width)")
#endif
            return
        }
        let visibleRange = table.rows(in: table.visibleRect)
        guard visibleRange.length > 0 else {
#if DEBUG
            cmuxDebugLog("sidebar.liveReflow.skip reason=noVisibleRows width=\(width)")
#endif
            return
        }
        let start = max(0, visibleRange.location - 2)
        let end = min(rows.count, visibleRange.location + visibleRange.length + 2)
        guard start < end else { return }
        lastLiveMeasuredWidth = width
        let changed = rowHeightCache.prepareRows(
            at: IndexSet(integersIn: start..<end),
            in: rows,
            columnWidth: width
        )
        hasLiveMeasuredRows = true
        for index in changed where rows.indices.contains(index) {
            pumpHeightOverrides.removeValue(forKey: rows[index].id)
        }
        if !changed.isEmpty {
            noteHeightOfRowsWithoutAnimation(table, changed)
        }
#if DEBUG
        cmuxDebugLog(
            "sidebar.liveReflow width=\(width) tableWidth=\(table.bounds.width) " +
            "rows=\(start)..<\(end) changed=\(changed.count)"
        )
#endif
    }

    /// Trailing re-measure fallback for width churn with no explicit end
    /// signal (window live resize); per-pixel drags otherwise re-measure
    /// every row every frame. Divider drags don't wait for this: the
    /// registry's end-of-resize notification triggers an immediate
    /// re-measure via performWidthRemeasureNow().
    private func scheduleWidthRemeasure() {
        widthRemeasureTask?.cancel()
        widthRemeasureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.widthRemeasureTask = nil
            self.performWidthRemeasureNow()
        }
    }

    /// Explicit resize-completion path: re-measures at the settled width
    /// immediately (drag just ended, geometry is final) and cancels any
    /// pending trailing fallback.
    func performWidthRemeasureNow() {
        guard isPresentationActive else { return }
        widthRemeasureTask?.cancel()
        widthRemeasureTask = nil
        let width = currentColumnWidth()
        guard width > 0 else { return }
        // A live partial pass leaves off-screen entries at the old width, so
        // it forces a full settle even when the drag ends back at the width
        // it started from.
        guard width != lastMeasuredWidth || hasLiveMeasuredRows else { return }
        var changed = rowHeightCache.prepareHostedRows(rows, columnWidth: width)
        lastMeasuredWidth = width
        hasLiveMeasuredRows = false
        lastLiveMeasuredWidth = 0
        // Same rule as apply(): released pump overrides change what
        // heightOfRow answers, so those rows re-note even when the cache
        // entry itself didn't move.
        if !pumpHeightOverrides.isEmpty {
            for (index, row) in rows.enumerated() where pumpHeightOverrides[row.id] != nil {
                changed.insert(index)
            }
        }
        pumpHeightOverrides.removeAll(keepingCapacity: true)
        if !changed.isEmpty {
            if let table = containerView?.tableView { noteHeightOfRowsWithoutAnimation(table, changed) }
        }
        if hasPendingContentRefresh {
            mutationScheduler.stageContentRefresh()
        }
    }

    private func currentColumnWidth() -> CGFloat {
        guard let containerView else { return 0 }
        return containerView.clipView.bounds.width
    }

    private func setHoveredRowId(_ next: SidebarWorkspaceRenderItemID?) {
        guard hoveredRowId != next else { return }
        let previous = hoveredRowId
        hoveredRowId = next
        reconfigureRows(withIds: [previous, next].compactMap { $0 })
    }

    private func contextMenuDidOpen(rowId: SidebarWorkspaceRenderItemID) {
        contextMenuRowId = rowId
    }

    private func contextMenuDidClose(rowId: SidebarWorkspaceRenderItemID) {
        guard contextMenuRowId == rowId else { return }
        contextMenuRowId = nil
        recomputeHoveredRow()
    }

    /// Legacy parity: the SwiftUI sidebar never animates row geometry (its
    /// "no implicit animation on agent-mutable fields" rule), but
    /// NSTableView animates noteHeightOfRows by default — rails and text
    /// visibly interpolated after width resizes.
    private func noteHeightOfRowsWithoutAnimation(_ table: NSTableView, _ indexes: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        table.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    /// Reconfigures content and commits its row heights in one AppKit
    /// transaction. The table's delegate sees the freshly prepared cache while
    /// the cell's layout is invalidated, so no intermediate frame can paint.
    private func reconfigureAndNoteRowsWithoutAnimation(
        _ contentRows: IndexSet,
        _ heightRows: IndexSet,
        in table: NSTableView
    ) {
        performTableGeometryUpdateWithoutAnimation(heightRows, in: table) {
            reconfigureVisibleRows(contentRows)
        }
    }

    /// Serializes any table geometry mutation with pump-driven height updates.
    private func performTableGeometryUpdateWithoutAnimation(
        _ heightRows: IndexSet = [],
        in table: NSTableView,
        update: () -> Void
    ) {
        isApplyingTableGeometryUpdate = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        update()
        var rowsToNote = heightRows
        for rowId in deferredPumpHeightRowIds {
            if let index = rows.firstIndex(where: { $0.id == rowId }) {
                rowsToNote.insert(index)
            }
        }
        if !rowsToNote.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: rowsToNote)
        }
        NSAnimationContext.endGrouping()
        isApplyingTableGeometryUpdate = false
        let latePumpRows = deferredPumpHeightRowIds
        deferredPumpHeightRowIds.removeAll(keepingCapacity: true)
        guard !latePumpRows.isEmpty else { return }
        let lateIndexes = IndexSet(rows.indices.compactMap { index in
            latePumpRows.contains(rows[index].id) ? index : nil
        })
        if !lateIndexes.isEmpty {
            noteHeightOfRowsWithoutAnimation(table, lateIndexes)
        }
    }

    private func reconfigureRows(withIds ids: [SidebarWorkspaceRenderItemID]) {
        let idSet = Set(ids)
        let indexes = IndexSet(rows.indices.filter { idSet.contains(rows[$0].id) })
        reconfigureVisibleRows(indexes)
    }

    /// Authoritative pass over visible cells so hover-revealed chrome (close
    /// button, header plus) cannot strand: per-transition repaints resolve
    /// ids against a rows array that can mutate in the same tick (content
    /// churn scrolling rows under a parked pointer), and a missed repaint
    /// left multiple rows showing hover chrome at once.
    private func enforceHoverOnVisibleCells() {
        guard let table = containerView?.tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        for row in visible.lowerBound..<(visible.lowerBound + visible.length)
        where rows.indices.contains(row) {
            let rowId = rows[row].id
            let hovering = hoveredRowId == rowId && contextMenuRowId != rowId
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarGroupHeaderTableCellView:
                cell.enforcePointerHovering(hovering)
            case let cell as SidebarWorkspaceRowTableCellView:
                cell.enforcePointerHovering(hovering)
            default:
                break
            }
        }
    }

    private func reconfigureVisibleRows(_ indexes: IndexSet) {
        guard let table = containerView?.tableView else { return }
        for row in indexes where rows.indices.contains(row) {
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarGroupHeaderTableCellView:
                configure(headerCell: cell, at: row)
            case let cell as SidebarWorkspaceRowTableCellView:
                configure(workspaceCell: cell, at: row)
            case let cell as SidebarWorkspaceTableCellView:
                configure(cell: cell, at: row)
            default:
                continue
            }
        }
    }

    private func configure(workspaceCell cell: SidebarWorkspaceRowTableCellView, at row: Int) {
        let configuration = rows[row]
        guard let model = configuration.appKitWorkspaceRowModel else { return }
        guard let actions = configuration.appKitWorkspaceRowActions else {
            cell.configurePresentation(model: model)
            return
        }
        let rowId = configuration.id
        cell.setPresentationActive(isPresentationActive)
        cell.configure(
            model: model,
            actions: actions,
            isPointerHovering: hoveredRowId == rowId && contextMenuRowId != rowId,
            contextMenuDidOpen: { [weak self] in
                self?.contextMenuDidOpen(rowId: rowId)
            },
            contextMenuDidClose: { [weak self] in
                self?.contextMenuDidClose(rowId: rowId)
            }
        )
        if let workspace = configuration.appKitWorkspaceRowWorkspace,
           let rebuild = configuration.appKitWorkspaceRowRebuild {
            cell.installPump(workspace: workspace) { [weak self, weak cell] in
                guard let self, let cell else { return }
                guard let rowIndex = self.rows.firstIndex(where: { $0.id == rowId }) else { return }
                var fresh = rebuild()
                // The workspace pump owns metadata/branch/PR churn, while the
                // unread snapshot owns these two fields. A replaying pump must
                // not put an older unread preview back over a committed row.
                if let currentModel = self.rows[rowIndex].appKitWorkspaceRowModel {
                    fresh.unreadCount = currentModel.unreadCount
                    fresh.latestNotificationText = currentModel.latestNotificationText
                }
                cell.applyRebuiltModel(fresh)
                self.noteRowHeightOverride(rowId: rowId, index: rowIndex, cell: cell, model: fresh)
            }
        }
        // configure() resets the drop lines from the model (always false
        // during a reorder drag); recycled/reconfigured cells must re-apply
        // the controller-owned paint or scrolling mid-drag drops the line.
        if let painter = reorderIndicatorPainter {
            let paint = painter.paint(forRowWorkspaceId: configuration.workspaceId)
            cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
        }
    }

    /// Pump-driven height corrections between applies: heightOfRow consults
    /// these before the equivalence-keyed cache (which only refreshes on the
    /// next container apply).
    private var pumpHeightOverrides: [SidebarWorkspaceRenderItemID: CGFloat] = [:]

    private func noteRowHeightOverride(
        rowId: SidebarWorkspaceRenderItemID,
        index: Int,
        cell: SidebarWorkspaceRowTableCellView,
        model: SidebarWorkspaceRowModel
    ) {
        guard let table = containerView?.tableView,
              rows.indices.contains(index), rows[index].id == rowId else { return }
        let row = rows[index]
        let width = currentColumnWidth()
        guard width > 0 else { return }
        let height = ceil(cell.layoutContent(model: model, width: width, apply: false))
        let current = pumpHeightOverrides[rowId]
            ?? rowHeightCache.height(for: row, columnWidth: width)
            ?? row.estimatedHeight
        guard abs(height - current) >= 0.5 else { return }
        pumpHeightOverrides[rowId] = height
        if isApplyingTableGeometryUpdate {
            deferredPumpHeightRowIds.insert(rowId)
        } else {
            noteHeightOfRowsWithoutAnimation(table, IndexSet(integer: index))
        }
    }

    private func configure(headerCell cell: SidebarGroupHeaderTableCellView, at row: Int) {
        let configuration = rows[row]
        guard let model = configuration.appKitGroupHeaderModel else { return }
        guard let actions = configuration.appKitGroupHeaderActions else {
            cell.configurePresentation(model: model)
            return
        }
        let rowId = configuration.id
        cell.configure(
            model: model,
            actions: actions,
            isPointerHovering: hoveredRowId == rowId && contextMenuRowId != rowId,
            contextMenuDidOpen: { [weak self] in
                self?.contextMenuDidOpen(rowId: rowId)
            },
            contextMenuDidClose: { [weak self] in
                self?.contextMenuDidClose(rowId: rowId)
            }
        )
        // Same recycled-cell rule as configure(workspaceCell:): re-apply the
        // controller-owned drop line after the model reset it.
        if let painter = reorderIndicatorPainter {
            let paint = painter.paint(forRowWorkspaceId: configuration.workspaceId)
            cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
        }
    }

    private func configure(cell: SidebarWorkspaceTableCellView, at row: Int) {
        let configuration = rows[row]
        let rowId = configuration.id
#if DEBUG
        cell.reconfigurationProbe = reconfigurationProbe
#endif
        cell.configure(
            row: configuration,
            isPointerHovering: hoveredRowId == rowId && contextMenuRowId != rowId,
            contextMenuDidOpen: { [weak self] in
                self?.contextMenuDidOpen(rowId: rowId)
            },
            contextMenuDidClose: { [weak self] in
                self?.contextMenuDidClose(rowId: rowId)
            }
        )
    }

    private func scrollSelectedRowToVisibleIfNeeded() {
        guard let table = containerView?.tableView,
              let selectedScrollTargetWorkspaceId,
              let row = rows.firstIndex(where: { $0.workspaceId == selectedScrollTargetWorkspaceId }) else {
            return
        }
        let visibleRect = table.visibleRect
        guard !visibleRect.contains(table.rect(ofRow: row)) else { return }
        table.scrollRowToVisible(row)
    }

    private func configureDropViews(
        in container: SidebarWorkspaceTableContainerView,
        actions: SidebarWorkspaceTableActions
    ) {
        let reorder = container.reorderDropView
        let livePayloadWorkspaceId = {
            Self.reorderPayloadWorkspaceId(NSPasteboard(name: .drag))
        }
        reorder.isValidDrag = {
            actions.isValidWorkspaceDrag()
        }
        reorder.hasLiveWorkspaceDrag = {
            if let nativeWorkspaceDragLifecycle = actions.nativeWorkspaceDragLifecycle {
                guard let sessionId = nativeWorkspaceDragLifecycle.currentSessionId() else { return false }
                return SidebarTabDragPayload.hasLiveSession(
                    in: NSPasteboard(name: .drag),
                    currentSessionId: sessionId
                )
            }
            // Compatibility action bundles predate the tokenized registry; in
            // those isolated clients the validity closure is their only live
            // session signal.
            return actions.isValidWorkspaceDrag()
        }
        reorder.updateDrag = { [weak self, weak reorder] point, _ in
            guard let self, let reorder else { return false }
            let targets = self.refreshReorderDropTargets()
            return self.updateReorderDrag(
                point: point,
                targets: targets,
                windowPoint: reorder.convert(point, to: nil),
                payloadWorkspaceId: livePayloadWorkspaceId()
            )
        }
        reorder.performDropAtPoint = { [weak self] point, _ in
            guard let self else { return false }
            return self.performReorderDrop(
                point: point,
                targets: self.refreshReorderDropTargets(),
                payloadWorkspaceId: livePayloadWorkspaceId()
            )
        }
        reorder.performPendingDropAtPoint = { [weak self] pendingDrop, _ in
            guard let self else { return false }
            let targets = self.refreshReorderDropTargets()
            if let performPendingWorkspaceDrop = actions.performPendingWorkspaceDrop {
                return performPendingWorkspaceDrop(pendingDrop, targets)
            }
            return false
        }
        reorder.clearDropIndicator = { [weak self] in
            self?.reorderDropDragExited()
        }
        reorder.setWorkspaceDropTargetCollectionActive = { [weak self] isActive in
            if isActive {
                self?.refreshReorderDropTargets()
            } else {
                self?.clearReorderDropTargets()
            }
        }

        let bonsplit = container.bonsplitDropView
        bonsplit.canPerformAction = actions.canPerformBonsplitAction
        bonsplit.updateAutoscroll = actions.updateDragAutoscroll
        bonsplit.setWorkspaceDropTargetCollectionActive = { [weak self] isActive in
            actions.setBonsplitDropTargetCollectionActive(isActive)
            guard let self else { return }
            if self.dropTargetGeometry.setBonsplitTargetCollectionActive(isActive, rows: self.rows) {
                self.positionAppKitDropIndicator()
            }
        }
        bonsplit.setDropIndicator = { [weak self] indicator in
            actions.setBonsplitDropIndicator(indicator)
            self?.setAppKitDropIndicator(indicator, scope: .raw, includeRowTargets: true)
        }
        bonsplit.performExistingWorkspaceMove = { workspaceId, transfer in
            guard actions.moveBonsplitToExistingWorkspace(workspaceId, transfer) else { return false }
            actions.didMoveBonsplitToWorkspace(workspaceId)
            return true
        }
        bonsplit.performNewWorkspaceMove = { insertionIndex, _, transfer in
            guard let workspaceId = actions.moveBonsplitToNewWorkspace(insertionIndex, transfer) else {
                return false
            }
            actions.didMoveBonsplitToWorkspace(workspaceId)
            return true
        }
    }

    private func clearDropViewActions(in container: SidebarWorkspaceTableContainerView) {
        let reorder = container.reorderDropView
        reorder.onPendingDropLifecycleEnded = nil
        reorder.suspendPresentation()
        reorder.isValidDrag = { false }
        reorder.hasLiveWorkspaceDrag = { false }
        reorder.updateDrag = { _, _ in false }
        reorder.performDropAtPoint = { _, _ in false }
        reorder.performPendingDropAtPoint = { _, _ in false }
        reorder.clearDropIndicator = {}
        reorder.setWorkspaceDropTargetCollectionActive = { _ in }

        let bonsplit = container.bonsplitDropView
        bonsplit.suspendPresentation()
        bonsplit.canPerformAction = { _, _ in false }
        bonsplit.updateAutoscroll = {}
        bonsplit.setWorkspaceDropTargetCollectionActive = { _ in }
        bonsplit.setDropIndicator = { _ in }
        bonsplit.performExistingWorkspaceMove = { _, _ in false }
        bonsplit.performNewWorkspaceMove = { _, _, _ in false }
    }

    private func updateDropTargets() {
        if dropTargetGeometry.refreshIfActive(rows: rows) {
            positionAppKitDropIndicator()
        }
    }

    private func synchronizeAppKitDropIndicator(actions: SidebarWorkspaceTableActions) {
        // A live reorder drag owns the indicator locally; dragState only
        // carries bonsplit indicators now, so syncing from it mid-reorder
        // would clear the past-the-end overlay on every apply.
        if let painter = reorderIndicatorPainter {
            setAppKitDropIndicator(painter.indicator, scope: painter.scope, includeRowTargets: false)
            return
        }
        let current = actions.currentDropIndicator()
        let currentScope = actions.currentDropIndicatorScope()
        if current == nil {
            setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
        } else if current == appKitDropIndicator && currentScope == appKitDropIndicatorScope {
            positionAppKitDropIndicator()
        } else {
            setAppKitDropIndicator(
                current,
                scope: currentScope,
                includeRowTargets: false
            )
        }
    }

    private func setAppKitDropIndicator(
        _ indicator: SidebarDropIndicator?,
        scope: SidebarWorkspaceReorderDropIndicatorScope,
        includeRowTargets: Bool
    ) {
        let shouldDisplay: Bool = {
            guard let indicator else { return false }
            if includeRowTargets { return true }
            guard !scope.isGroup else { return false }
            if indicator.tabId == nil { return true }
            return indicator.edge == .bottom && rows.last?.workspaceId == indicator.tabId
        }()
        appKitDropIndicator = shouldDisplay ? indicator : nil
        appKitDropIndicatorScope = scope
        appKitDropIndicatorIncludesRowTargets = includeRowTargets
        containerView?.emptyDropIndicatorView.isHidden = !shouldDisplay
        positionAppKitDropIndicator()
    }

    private func positionAppKitDropIndicator() {
        guard let indicator = appKitDropIndicator, let container = containerView else { return }
        let targetRow = indicator.tabId.flatMap { tabId in
            rows.firstIndex { $0.workspaceId == tabId }
        }
        if indicator.tabId != nil, targetRow == nil {
            container.emptyDropIndicatorView.isHidden = true
            return
        }
        container.emptyDropIndicatorView.isHidden = false
        let y: CGFloat
        if let targetRow {
            let rowFrame = container.tableView.convert(
                container.tableView.rect(ofRow: targetRow),
                to: container
            )
            y = (indicator.edge == .top ? rowFrame.maxY : rowFrame.minY) - 1
        } else if let lastRow = rows.indices.last {
            y = container.tableView.convert(
                container.tableView.rect(ofRow: lastRow),
                to: container
            ).minY - 1
        } else {
            y = container.bounds.height
                - SidebarWorkspaceScrollInsets.workspaceList.top
                - SidebarWorkspaceListMetrics.rowVerticalPadding
        }
        let leadingIndent: CGFloat = {
            guard appKitDropIndicatorIncludesRowTargets,
                  let targetRow,
                  rows[targetRow].groupId != nil,
                  !rows[targetRow].isGroupHeader else {
                return 0
            }
            return SidebarWorkspaceGroupingMetrics.memberIndent
        }()
        container.emptyDropIndicatorView.frame = NSRect(
            x: 8 + leadingIndent,
            y: y,
            width: max(0, container.bounds.width - 16 - leadingIndent),
            height: 2
        )
    }
}
