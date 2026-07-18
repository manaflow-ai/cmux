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
    private let rowHeightCache = SidebarWorkspaceTableRowHeightCache()
    private let dropTargetGeometry = SidebarWorkspaceTableDropTargetGeometryGate()
    private let selectionInteraction = SignalClickDragInteraction<UUID, NSEvent.ModifierFlags>()
    private lazy var selectionInteractionEffect = selectionInteraction.observePhase { [weak self] phase, context in
        guard let self,
              case let .activating(workspaceId, modifiers) = phase else { return }
        let extendsSelection = modifiers.contains(.command) || modifiers.contains(.shift)
        if !extendsSelection {
            self.previewSelection(workspaceId: workspaceId)
            context.onCleanup { [weak self] in
                self?.restoreAuthoritativeSelectionAppearance()
            }
        }
        self.commitSelection(workspaceId: workspaceId, modifiers: modifiers)
    }

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
    }
    func makeContainerView() -> SidebarWorkspaceTableContainerView {
        let container = SidebarWorkspaceTableContainerView()
        containerView = container
        _ = selectionInteractionEffect

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
        self.actions = actions
        actions.attachScrollView(containerView.scrollView)
        configureDropViews(in: containerView, actions: actions)

        let previousRows = rows
        let hasStructuralChanges = previousRows.map(\.id) != nextRows.map(\.id)
        let contentChanges = IndexSet(nextRows.indices.filter { index in
            previousRows.indices.contains(index)
                && !previousRows[index].hasEquivalentContent(to: nextRows[index])
        })
        let width = currentColumnWidth()
        var heightChanges = IndexSet()
        if width == lastMeasuredWidth || lastMeasuredWidth == 0 {
            heightChanges = rowHeightCache.prepareHostedRows(nextRows, columnWidth: width)
            if width > 0 { lastMeasuredWidth = width }
        } else {
            // Divider drag in flight: keep last-width heights (text truncates
            // live) and re-measure once the width settles.
            scheduleWidthRemeasure()
        }
        pumpHeightOverrides.removeAll(keepingCapacity: true)
        rows = nextRows

        if hasStructuralChanges {
            containerView.tableView.reloadData()
        } else {
            reconfigureVisibleRows(contentChanges)
            if !heightChanges.isEmpty {
                containerView.tableView.noteHeightOfRows(withIndexesChanged: heightChanges)
            }
        }
        reconcileSelectionInteraction(in: nextRows)

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
        if rows[row].appKitWorkspaceRowActions != nil {
            let workspaceId = rows[row].workspaceId
            // The action is AppKit's completed-click event. A drag moves the
            // signal to `.dragging`, so it cannot pass this activation gate.
            selectionInteraction.mouseUpWithoutDrag(on: workspaceId)
        } else if let headerActions = rows[row].appKitGroupHeaderActions {
            headerActions.onFocusAnchor()
        }
    }

    @objc private func didDoubleClickTableRow() {
        guard let table = containerView?.tableView else { return }
        let row = table.clickedRow
        guard rows.indices.contains(row),
              rows[row].appKitWorkspaceRowModel != nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView else { return }
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
        selectionInteraction.dragDidBegin(on: workspaceId)
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
        selectionInteraction.dragDidEnd()
    }

    func workspaceDragSessionDidBegin() {
        if dropTargetGeometry.setWorkspaceDragSessionActive(true, rows: rows) {
            positionAppKitDropIndicator()
        }
    }

    func workspaceDragSessionDidEnd() {
        dropTargetGeometry.setWorkspaceDragSessionActive(false, rows: rows)
        dropTargetGeometry.setReorderTargetCollectionActive(false, rows: rows)
    }

    /// Begins a signal-owned pointer interaction without changing selection.
    /// AppKit decides whether this press becomes a drag or a completed click.
    func pointerMouseDown(row: Int, modifiers: NSEvent.ModifierFlags, hitView: NSView?) {
        guard rows.indices.contains(row),
              rows[row].appKitWorkspaceRowModel != nil,
              let table = containerView?.tableView,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView else { return }
        if let hitView, cell.selectionPreviewShouldIgnore(hitView) { return }
        selectionInteraction.mouseDown(on: rows[row].workspaceId, context: modifiers)
    }

    func pointerTrackingDidEnd() {
        selectionInteraction.trackingDidEnd()
    }

    /// Completed-click highlight: paints the clicked workspace cell as
    /// selected immediately on mouse-up and peels the highlight off
    /// the outgoing rows so old and new selection never show together while
    /// the authoritative render is queued behind the terminal-view swap.
    /// The signal cleanup reconciles after the authoritative apply.
    private func previewSelection(workspaceId: UUID) {
        guard let row = rows.firstIndex(where: { $0.workspaceId == workspaceId }),
              rows[row].appKitWorkspaceRowModel != nil,
              let table = containerView?.tableView,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView else { return }
        let visibleRows = table.rows(in: table.visibleRect)
        for visibleRow in visibleRows.lowerBound..<(visibleRows.lowerBound + visibleRows.length)
        where visibleRow != row {
            (table.view(atColumn: 0, row: visibleRow, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView)?.showOptimisticDeselection()
        }
        cell.showOptimisticSelectionHighlight()
    }

    private func restoreAuthoritativeSelectionAppearance() {
        guard let table = containerView?.tableView else { return }
        let visibleRows = table.rows(in: table.visibleRect)
        for row in visibleRows.lowerBound..<(visibleRows.lowerBound + visibleRows.length) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView)?.restoreAuthoritativeSelectionAppearance()
        }
    }

    /// The signal effect is the single selection-commit owner. It resolves the
    /// row action at effect time and preserves mouse-down modifiers across any
    /// coalesced trailing commit.
    private func commitSelection(workspaceId: UUID, modifiers: NSEvent.ModifierFlags) {
        guard let row = rows.first(where: { $0.workspaceId == workspaceId }),
              let actions = row.appKitWorkspaceRowActions else { return }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            // Multi-select mutations are order-dependent; apply in order,
            // never dropping intermediates.
            selectionCoalescer.cancel()
            actions.commands.updateSelection(modifiers: modifiers)
            // Modified selection commits synchronously and does not use
            // optimistic blue feedback, so no reconciliation wait is needed.
            selectionInteraction.activationDidReconcile(id: workspaceId)
        } else {
            selectionCoalescer.request {
                actions.commands.updateSelection(modifiers: modifiers)
            }
            // Clicking the already-active workspace is an authoritative no-op,
            // so no later apply exists to close the activation phase.
            if row.appKitWorkspaceRowModel?.isActive == true {
                selectionInteraction.activationDidReconcile(id: workspaceId)
            }
        }
    }

    private func reconcileSelectionInteraction(in nextRows: [SidebarWorkspaceTableRowConfiguration]) {
        guard case let .activating(workspaceId, modifiers) = selectionInteraction.phase else { return }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            selectionInteraction.activationDidReconcile(id: workspaceId)
            return
        }
        guard nextRows.first(where: { $0.workspaceId == workspaceId })?
            .appKitWorkspaceRowModel?.isActive == true else { return }
        selectionInteraction.activationDidReconcile(id: workspaceId)
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
        if width > 0, width != lastMeasuredWidth {
            scheduleWidthRemeasure()
        }
        recomputeHoveredRow()
        enforceHoverOnVisibleCells()
        updateDropTargets()
    }

    private let selectionCoalescer = SidebarSelectionCoalescer()
    private var lastMeasuredWidth: CGFloat = 0
    private var widthRemeasureTask: Task<Void, Never>?

    /// One trailing re-measure ~120ms after the sidebar width stops moving;
    /// per-pixel divider drags otherwise re-measure every row every frame.
    private func scheduleWidthRemeasure() {
        widthRemeasureTask?.cancel()
        widthRemeasureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.widthRemeasureTask = nil
            let width = self.currentColumnWidth()
            guard width > 0 else { return }
            let changed = self.rowHeightCache.prepareHostedRows(self.rows, columnWidth: width)
            self.lastMeasuredWidth = width
            self.pumpHeightOverrides.removeAll(keepingCapacity: true)
            if !changed.isEmpty {
                self.containerView?.tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
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
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
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
