import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation

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
    private var rowIndexById: [SidebarWorkspaceRenderItemID: Int] = [:]
    private lazy var mutationScheduler = SidebarWorkspaceTableMutationScheduler(
        applyFlush: { [weak self] in self?.flushApply($0) },
        viewportChangeFlush: { [weak self] in self?.flushViewportChange() }
    )
    private let rowHeightCache = SidebarWorkspaceTableRowHeightCache()
    private let dropTargetGeometry = SidebarWorkspaceTableDropTargetGeometryGate()
    private let emptyAreaMenuOwner = SidebarWorkspaceTableEmptyAreaMenuOwner()

#if DEBUG
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
        container.workspaceController = self

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
        selectedScrollTargetWorkspaceId: UUID?,
        isDividerDragActive: Bool = false
    ) {
        mutationScheduler.stageApply(
            SidebarWorkspaceTableApplyInput(
                rows: nextRows,
                actions: actions,
                workspaceIds: nextWorkspaceIds,
                selectedWorkspaceId: selectedWorkspaceId,
                selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId,
                isDividerDragActive: isDividerDragActive
            )
        )
    }

    private func flushApply(_ input: SidebarWorkspaceTableApplyInput) {
        guard let containerView else { return }
        let nextRows = input.rows
        let actions = input.actions
        let nextWorkspaceIds = input.workspaceIds
        let selectedWorkspaceId = input.selectedWorkspaceId
        let selectedScrollTargetWorkspaceId = input.selectedScrollTargetWorkspaceId
        isDividerDragActive = input.isDividerDragActive
        self.actions = actions
        actions.attachScrollView(containerView.scrollView)
        configureDropViews(in: containerView, actions: actions)

        let previousRows = rows
        let hasStructuralChanges = !previousRows.elementsEqual(nextRows) { $0.id == $1.id }
        let width = currentColumnWidth()
        var heightChanges = IndexSet()
        if width == lastMeasuredWidth || lastMeasuredWidth == 0 {
            heightChanges = rowHeightCache.prepareNativeRows(nextRows, columnWidth: width)
            if width > 0 { lastMeasuredWidth = width }
        }
        rows = nextRows
        rowIndexById = Dictionary(
            nextRows.enumerated().lazy.map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if hasStructuralChanges {
            containerView.tableView.reloadData()
        } else {
            let contentChanges = IndexSet(nextRows.indices.filter { index in
                !previousRows[index].hasEquivalentContent(to: nextRows[index])
            })
            reconfigureVisibleRows(contentChanges)
            if !heightChanges.isEmpty {
                containerView.tableView.noteHeightOfRows(withIndexesChanged: heightChanges)
            }
        }

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
        reconcileVisibleCells()
        updateDropTargets()
        if !isWindowLiveResizeActive {
            remeasureRowsIfWidthChanged()
        }
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
            // Capture modifiers at click time: a coalesced (trailing) apply
            // must not re-read the keyboard ~100ms later.
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                // Multi-select mutations are order-dependent; apply in order,
                // never dropping intermediates.
                selectionCoalescer.cancel()
                actions.commands.updateSelection(modifiers: modifiers)
            } else {
                selectionCoalescer.request {
                    actions.commands.updateSelection(modifiers: modifiers)
                }
            }
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
        assertionFailure("Sidebar table row \(rows[row].id) has no native cell model")
        return nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let actions,
              !isInlineEditing(row: row, tableView: tableView) else { return nil }
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
        // A cancelled drag can end without `draggingExited` reaching the drop
        // views, so clear any AppKit-owned indicator on every session end.
        setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
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

    /// Optimistic press highlight: paints the clicked workspace cell as
    /// selected immediately and, for a plain click, peels the highlight off
    /// the outgoing rows so old and new selection never show together while
    /// the authoritative render is queued behind the terminal-view swap.
    /// The authoritative apply reconciles right after.
    func previewSelection(row: Int, modifiers: NSEvent.ModifierFlags, hitView: NSView?) {
        guard rows.indices.contains(row),
              rows[row].appKitWorkspaceRowModel != nil,
              let table = containerView?.tableView,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView else { return }
        if let hitView, cell.selectionPreviewShouldIgnore(hitView) { return }
        let extendsSelection = modifiers.contains(.command) || modifiers.contains(.shift)
        if !extendsSelection {
            let visibleRows = table.rows(in: table.visibleRect)
            for visibleRow in visibleRows.lowerBound..<(visibleRows.lowerBound + visibleRows.length)
            where visibleRow != row {
                (table.view(atColumn: 0, row: visibleRow, makeIfNecessary: false)
                    as? SidebarWorkspaceRowTableCellView)?.showOptimisticDeselection()
            }
        }
        cell.showOptimisticSelectionHighlight()
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
        emptyAreaMenuOwner.createEmptyWorkspaceGroup(actions: actions)
    }

    func emptyAreaMenu() -> NSMenu {
        emptyAreaMenuOwner.menu(actions: actions)
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
        mutationScheduler.stageViewportChange()
    }

    private func flushViewportChange() {
        if !isWindowLiveResizeActive {
            remeasureRowsIfWidthChanged()
        }
        recomputeHoveredRow()
        reconcileVisibleCells()
        updateDropTargets()
    }

    private let selectionCoalescer = SidebarSelectionCoalescer()
    private var lastMeasuredWidth: CGFloat = 0
    private var isDividerDragActive = false

    /// Reconciles cached native heights at a settled resize boundary.
    func remeasureRowsIfWidthChanged() {
        guard !isDividerDragActive else { return }
        let width = currentColumnWidth()
        guard width > 0, width != lastMeasuredWidth else { return }
        let changed = rowHeightCache.prepareNativeRows(rows, columnWidth: width)
        lastMeasuredWidth = width
        if !changed.isEmpty {
            containerView?.tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
    }

    private var isWindowLiveResizeActive: Bool {
        containerView?.inLiveResize == true || containerView?.window?.inLiveResize == true
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

    func contextMenuDidOpen(rowId: SidebarWorkspaceRenderItemID) {
        guard contextMenuRowId != rowId else { return }
        let previous = contextMenuRowId
        contextMenuRowId = rowId
        reconfigureRows(withIds: [previous, rowId].compactMap { $0 })
    }

    func contextMenuDidClose(rowId: SidebarWorkspaceRenderItemID) {
        guard contextMenuRowId == rowId else { return }
        contextMenuRowId = nil
        recomputeHoveredRow()
        reconfigureRows(withIds: [rowId])
    }

    private func reconfigureRows(withIds ids: [SidebarWorkspaceRenderItemID]) {
        let indexes = IndexSet(ids.compactMap { rowIndexById[$0] })
        reconfigureVisibleRows(indexes)
    }

    /// Authoritative pass over visible cells. Action bundles always refresh,
    /// even when their value models are equivalent, and hover-revealed chrome
    /// reconciles against the latest row identity after content churn.
    private func reconcileVisibleCells() {
        guard let table = containerView?.tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        for row in visible.lowerBound..<(visible.lowerBound + visible.length)
        where rows.indices.contains(row) {
            let rowId = rows[row].id
            let hovering = hoveredRowId == rowId && contextMenuRowId != rowId
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarGroupHeaderTableCellView:
                if let actions = rows[row].appKitGroupHeaderActions {
                    cell.updateActions(actions)
                }
                cell.enforcePointerHovering(hovering)
            case let cell as SidebarWorkspaceRowTableCellView:
                if let actions = rows[row].appKitWorkspaceRowActions {
                    cell.updateActions(actions)
                }
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

    private func scrollSelectedRowToVisibleIfNeeded() {
        guard let table = containerView?.tableView,
              let selectedScrollTargetWorkspaceId,
              let row = rowIndex(forWorkspaceId: selectedScrollTargetWorkspaceId) else {
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
        bonsplit.performNewWorkspaceMove = { [weak self] _, indicator, transfer in
            guard let self else { return false }
            let insertionIndex = self.workspaceInsertionIndex(for: indicator)
            guard let workspaceId = actions.moveBonsplitToNewWorkspace(insertionIndex, transfer) else {
                return false
            }
            actions.didMoveBonsplitToWorkspace(workspaceId)
            return true
        }
    }

    private func workspaceInsertionIndex(for indicator: SidebarDropIndicator) -> Int {
        guard let tabId = indicator.tabId,
              let index = workspaceIds.firstIndex(of: tabId) else {
            return workspaceIds.count
        }
        guard let groupId = rows.first(where: { $0.workspaceId == tabId })?.groupId,
              let header = rows.first(where: {
                  $0.appKitGroupHeaderModel?.groupId == groupId
              })?.appKitGroupHeaderModel,
              let anchorIndex = workspaceIds.firstIndex(of: header.anchorWorkspaceId) else {
            return indicator.edge == .bottom ? index + 1 : index
        }
        if indicator.edge == .bottom {
            return min(workspaceIds.count, anchorIndex + header.memberCount)
        }
        return anchorIndex
    }

    private func isInlineEditing(row: Int, tableView: NSTableView) -> Bool {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
            return false
        }
        if let workspaceCell = cell as? SidebarWorkspaceRowTableCellView,
           workspaceCell.suppressesWorkspaceDrag {
            return true
        }
        guard let responder = tableView.window?.firstResponder as? NSView else { return false }
        return responder === cell || responder.isDescendant(of: cell)
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
        let targetRow = indicator.tabId.flatMap(rowIndex(forWorkspaceId:))
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

    /// Resolves workspace-targeted behavior to the concrete workspace row
    /// when it is visible, falling back to the group's anchor-backed header
    /// when the workspace row is collapsed or otherwise absent.
    func rowIndex(forWorkspaceId workspaceId: UUID) -> Int? {
        if let workspaceRow = rowIndexById[.workspace(workspaceId)] {
            return workspaceRow
        }
        return rows.firstIndex {
            $0.isGroupHeader && $0.workspaceId == workspaceId
        }
    }
}
