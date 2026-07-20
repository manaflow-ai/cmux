import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Main-actor owner of the default sidebar table lifecycle and its AppKit interactions.
@MainActor
final class SidebarWorkspaceTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var containerView: SidebarWorkspaceTableContainerView?
    private var rows: [SidebarWorkspaceTableRowConfiguration] = []
    private var actions: SidebarWorkspaceTableActions?
    private var hoveredRowId: SidebarWorkspaceRenderItemID?
    private var contextMenuRowId: SidebarWorkspaceRenderItemID?
    private var workspaceIds: [UUID] = []
    private var selectedScrollTargetWorkspaceId: UUID?
    private var appKitDropIndicator: SidebarDropIndicator?
    private var appKitDropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw
    private var appKitDropIndicatorIncludesRowTargets = false
    private var clipBoundsObserver: NSObjectProtocol?
    private var resizeDidEndObserver: NSObjectProtocol?
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
        table.setDraggingSourceOperationMask(.move, forLocal: false)

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
            NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier),
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
                self?.performWidthRemeasureNow()
            }
        }

        return container
    }

    func apply(
        rows nextRows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds nextWorkspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?
    ) {
        guard let containerView else { return }
        // Authoritative render: reconciles any optimistic preview, so the
        // preview bailout stands down.
        applyGeneration &+= 1
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        self.actions = actions
        actions.attachScrollView(containerView.scrollView)
        configureDropViews(in: containerView, actions: actions)

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
            let previousIds = previousRows.map(\.id)
            let nextIds = nextRows.map(\.id)
            // Positional mismatches bound the number of moveRow calls a drag
            // needs (a single dragged row misaligns one contiguous span).
            // Multiset equality (not Set) so duplicate ids — corrupt state —
            // never masquerade as a pure reorder; and past the threshold the
            // move planner's rescans would go quadratic, so bulk permutations
            // take the reload path (they gain nothing from animation).
            let mismatches = zip(previousIds, nextIds).reduce(into: 0) { count, pair in
                if pair.0 != pair.1 { count += 1 }
            }
            if previousIds.count == nextIds.count,
               mismatches <= Self.maxAnimatedReorderMoves,
               Self.multisetEqual(previousIds, nextIds) {
                // Pure reorder (drag-drop): move rows in place. reloadData
                // tears down every visible cell and snaps the scroll
                // position — the "click to reorder is jank" report — while
                // moves keep cells alive and settle smoothly.
                let table = containerView.tableView
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
                if !heightChanges.isEmpty {
                    noteHeightOfRowsWithoutAnimation(table, heightChanges)
                }
            } else {
                containerView.tableView.reloadData()
            }
        } else {
            reconfigureVisibleRows(contentChanges)
            if !heightChanges.isEmpty {
                noteHeightOfRowsWithoutAnimation(containerView.tableView, heightChanges)
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
        if selectionTargetChanged || shouldScrollAfterWorkspaceChange {
            scrollSelectedRowToVisibleIfNeeded()
        }
        synchronizeAppKitDropIndicator(actions: actions)
        recomputeHoveredRow()
        enforceHoverOnVisibleCells()
        updateDropTargets()
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
        if let actions = rows[row].appKitWorkspaceRowActions {
            // Capture modifiers from the clicking EVENT at action time: a
            // coalesced (trailing) apply must not re-read the keyboard
            // ~100ms later, and the global NSEvent.modifierFlags reads
            // hardware state, which misses event-carried flags (synthetic
            // clicks, exotic input methods).
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            // Down-then-up highlight: the optimistic paint bridges the model
            // round trip, applied here (action == completed click), never on
            // the press.
            previewSelection(row: row, modifiers: modifiers, hitView: nil)
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                // Multi-select mutations are order-dependent and extend the
                // selection the user currently sees: flush (not drop) a
                // plain click still in the coalescing window first.
                selectionCoalescer.flushNow()
                actions.commands.updateSelection(modifiers: modifiers)
            } else {
                selectionCoalescer.request {
                    actions.commands.updateSelection(modifiers: modifiers)
                }
            }
        } else if let headerActions = rows[row].appKitGroupHeaderActions {
            // Group headers focus their anchor workspace: same fast path as
            // workspace rows (burst coalescing; the completed click paints
            // the optimistic anchor-active treatment).
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            previewSelection(row: row, modifiers: modifiers, hitView: nil)
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                selectionCoalescer.flushNow()
                headerActions.onFocusAnchor()
            } else {
                selectionCoalescer.request {
                    headerActions.onFocusAnchor()
                }
            }
        }
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
        selectionCoalescer.cancel()
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
            configure(headerCell: cell, at: row)
            return cell
        }
        if rows[row].appKitWorkspaceRowModel != nil {
            let cell = tableView.makeView(
                withIdentifier: SidebarWorkspaceRowTableCellView.reuseIdentifier,
                owner: self
            ) as? SidebarWorkspaceRowTableCellView ?? SidebarWorkspaceRowTableCellView()
            configure(workspaceCell: cell, at: row)
            return cell
        }
        let cell = tableView.makeView(
            withIdentifier: SidebarWorkspaceTableCellView.reuseIdentifier,
            owner: self
        ) as? SidebarWorkspaceTableCellView ?? SidebarWorkspaceTableCellView()
        configure(cell: cell, at: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // Group headers carry their anchor's workspaceId; a header drag would
        // masquerade as dragging the anchor workspace and tear it out of the
        // group. Headers are not row-draggable in the SwiftUI sidebar either.
        guard rows.indices.contains(row), !rows[row].isGroupHeader, let actions else { return nil }
        let workspaceId = rows[row].workspaceId
        actions.beginWorkspaceDrag(workspaceId)
        workspaceDragSessionDidBegin()
        let item = NSPasteboardItem()
        item.setString(
            "\(SidebarTabDragPayload.prefix)\(workspaceId.uuidString)",
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        actions?.endWorkspaceDrag()
        workspaceDragSessionDidEnd()
    }

    func workspaceDragSessionDidBegin() {
        // A drag consumes the press: the click action never fires, so no
        // authoritative selection apply will reconcile the optimistic press
        // highlight painted in previewSelection — without this rollback a
        // fast drag leaves the grabbed row painted selected and every other
        // visible row peeled. Drop the queued selection and restore visible
        // cells from their stored models before drop targets paint.
        selectionCoalescer.cancel()
        previewBailoutTask?.cancel()
        previewBailoutTask = nil
        restoreVisibleCellPaint()
        if dropTargetGeometry.setWorkspaceDragSessionActive(true, rows: rows) {
            positionAppKitDropIndicator()
        }
    }

    func workspaceDragSessionDidEnd() {
        dropTargetGeometry.setWorkspaceDragSessionActive(false, rows: rows)
        dropTargetGeometry.setReorderTargetCollectionActive(false, rows: rows)
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
                // Headers preview anchor-active the same way workspace rows
                // preview selection; a replaced header preview must peel too.
                (cellView as? SidebarGroupHeaderTableCellView)?.clearOptimisticAnchorActive()
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
        headerCell?.showOptimisticAnchorActive()
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
            (cellView as? SidebarGroupHeaderTableCellView)?.clearOptimisticAnchorActive()
        }
    }

    func middleClick(row: Int) {
        // Group headers carry their anchor's workspaceId; middle-closing the
        // anchor from a header press would be destructive and non-parity.
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
        guard let model = configuration.appKitWorkspaceRowModel,
              let actions = configuration.appKitWorkspaceRowActions else { return }
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
        if let workspace = configuration.appKitWorkspaceRowWorkspace,
           let rebuild = configuration.appKitWorkspaceRowRebuild {
            cell.installPump(workspace: workspace) { [weak self, weak cell] in
                guard let self, let cell else { return }
                let fresh = rebuild()
                cell.applyRebuiltModel(fresh)
                self.noteRowHeightOverride(rowId: rowId, cell: cell, model: fresh)
            }
        }
    }

    /// Pump-driven height corrections between applies: heightOfRow consults
    /// these before the equivalence-keyed cache (which only refreshes on the
    /// next container apply).
    private var pumpHeightOverrides: [SidebarWorkspaceRenderItemID: CGFloat] = [:]

    private func noteRowHeightOverride(
        rowId: SidebarWorkspaceRenderItemID,
        cell: SidebarWorkspaceRowTableCellView,
        model: SidebarWorkspaceRowModel
    ) {
        guard let table = containerView?.tableView,
              let index = rows.firstIndex(where: { $0.id == rowId }) else { return }
        let height = ceil(cell.layoutContent(model: model, width: currentColumnWidth(), apply: false))
        let current = table.rect(ofRow: index).height
        guard abs(height - current) >= 0.5 else { return }
        pumpHeightOverrides[rowId] = height
        noteHeightOfRowsWithoutAnimation(table, IndexSet(integer: index))
    }

    private func configure(headerCell cell: SidebarGroupHeaderTableCellView, at row: Int) {
        let configuration = rows[row]
        guard let model = configuration.appKitGroupHeaderModel,
              let actions = configuration.appKitGroupHeaderActions else { return }
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
        reorder.isValidDrag = actions.isValidWorkspaceDrag
        reorder.updateDrag = { [weak self] point, targets in
            let accepted = actions.updateWorkspaceDrag(point, targets)
            self?.setAppKitDropIndicator(
                actions.currentDropIndicator(),
                scope: actions.currentDropIndicatorScope(),
                includeRowTargets: false
            )
            return accepted
        }
        reorder.performDropAtPoint = { [weak self] point, targets in
            let performed = actions.performWorkspaceDrop(point, targets)
#if DEBUG
            // Every silent "the workspace I dragged didn't move" report needs
            // this line: where the drop landed, how many targets existed, and
            // whether the shared planner accepted it.
            cmuxDebugLog(
                "sidebar.drop.perform point=(\(Int(point.x)),\(Int(point.y))) " +
                "targets=\(targets.count) performed=\(performed ? 1 : 0)"
            )
#endif
            self?.setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
            return performed
        }
        reorder.clearDropIndicator = { [weak self] in
            actions.clearWorkspaceDropIndicator()
            self?.setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
        }
        reorder.setWorkspaceDropTargetCollectionActive = { [weak self] isActive in
            actions.setWorkspaceDropTargetCollectionActive(isActive)
            guard let self else { return }
            if self.dropTargetGeometry.setReorderTargetCollectionActive(isActive, rows: self.rows) {
                self.positionAppKitDropIndicator()
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

    private func updateDropTargets() {
        if dropTargetGeometry.refreshIfActive(rows: rows) {
            positionAppKitDropIndicator()
        }
    }

    private func synchronizeAppKitDropIndicator(actions: SidebarWorkspaceTableActions) {
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
