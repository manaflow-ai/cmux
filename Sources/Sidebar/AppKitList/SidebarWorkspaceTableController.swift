import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Callbacks a workspace cell needs from its hosting controller.
@MainActor
struct SidebarWorkspaceCellHost {
    /// Ends the inline-rename session for the represented row (after the
    /// rename field committed or cancelled).
    let endRename: () -> Void
}

/// Main-actor owner of the default sidebar table lifecycle and its AppKit
/// interactions: virtualization, diffing, hover, clicks, inline rename,
/// context menus, drag sources, and drop-target geometry.
///
/// The controller consumes immutable `SidebarWorkspaceListRow` values plus
/// closure bundles. It holds no reference to any observable model, so no
/// workspace mutation can invalidate layout from below — the livelock class
/// this rewrite removes is unrepresentable here.
@MainActor
final class SidebarWorkspaceTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private weak var containerView: SidebarWorkspaceTableContainerView?
    private var rows: [SidebarWorkspaceListRow] = []
    private var rowIndexById: [SidebarWorkspaceRenderItemID: Int] = [:]
    private var listActions: SidebarWorkspaceTableActions?
    private var actionResolver: SidebarWorkspaceListActionResolver?
    private var environment: SidebarWorkspaceListEnvironment = .default
    private var hoveredRowId: SidebarWorkspaceRenderItemID?
    private var contextMenuRowId: SidebarWorkspaceRenderItemID?
    private var openContextMenu: NSMenu?
    private var editingWorkspaceId: UUID?
    private var workspaceIds: [UUID] = []
    private var selectedScrollTargetWorkspaceId: UUID?
    private var appKitDropIndicator: SidebarDropIndicator?
    private var appKitDropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw
    private var appKitDropIndicatorIncludesRowTargets = false
    private var clipBoundsObserver: NSObjectProtocol?
    private var isDragSessionActive = false
    private(set) var didBeginDragDuringMouseTracking = false
    private let rowHeightCache = SidebarWorkspaceTableRowHeightCache(
        makeWorkspaceSizingCell: { SidebarWorkspaceTableCellView() },
        makeGroupHeaderSizingCell: { SidebarWorkspaceGroupHeaderCellView() }
    )
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
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.intercellSpacing = NSSize(width: 0, height: SidebarWorkspaceListEnvironment.default.rowSpacing)
        table.usesAutomaticRowHeights = false
        table.rowHeight = SidebarWorkspaceTableRowHeightCalculator().defaultWorkspaceHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.move, forLocal: false)
        table.setAccessibilityIdentifier("SidebarWorkspaceList")

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

        // Cell-local transient state (metadata show-more, checklist add/edit)
        // changes rendered height without changing the row snapshot; the cache
        // must drop that row's entry and re-measure.
        SidebarWorkspaceCellTransientState.shared.addObserver(owner: self) { [weak self] workspaceId in
            self?.transientRowStateDidChange(workspaceId: workspaceId)
        }

        return container
    }

    private func transientRowStateDidChange(workspaceId: UUID) {
        let rowId = SidebarWorkspaceRenderItemID.workspace(workspaceId)
        guard let index = rowIndexById[rowId] else { return }
        rowHeightCache.invalidate(id: rowId)
        let changed = rowHeightCache.prepare(
            rows: rows,
            columnWidth: currentColumnWidth(),
            environment: environment
        )
        reconfigureRows(withIds: [rowId])
        var heightIndexes = changed
        heightIndexes.insert(index)
        containerView?.tableView.noteHeightOfRows(withIndexesChanged: heightIndexes)
    }

    func apply(
        rows nextRows: [SidebarWorkspaceListRow],
        listActions: SidebarWorkspaceTableActions,
        actionResolver: @escaping SidebarWorkspaceListActionResolver,
        environment nextEnvironment: SidebarWorkspaceListEnvironment,
        workspaceIds nextWorkspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?
    ) {
        guard let containerView else { return }
        self.listActions = listActions
        self.actionResolver = actionResolver
        listActions.attachScrollView(containerView.scrollView)
        configureDropViews(in: containerView, actions: listActions)

        if let editingWorkspaceId,
           !nextRows.contains(where: { !$0.isGroupHeader && $0.workspaceId == editingWorkspaceId }) {
            self.editingWorkspaceId = nil
        }

        let previousRows = rows
        let environmentChanged = environment != nextEnvironment
        environment = nextEnvironment
        if environmentChanged {
            containerView.tableView.intercellSpacing = NSSize(
                width: 0,
                height: nextEnvironment.rowSpacing
            )
        }
        let hasStructuralChanges = previousRows.count != nextRows.count
            || zip(previousRows, nextRows).contains { $0.id != $1.id }
        let contentChanges = IndexSet(nextRows.indices.filter { index in
            previousRows.indices.contains(index)
                && (environmentChanged || previousRows[index] != nextRows[index])
        })
        let heightChanges = rowHeightCache.prepare(
            rows: nextRows,
            columnWidth: currentColumnWidth(),
            environment: environment
        )
        rows = nextRows
        rowIndexById = Dictionary(
            uniqueKeysWithValues: nextRows.enumerated().map { ($0.element.id, $0.offset) }
        )

        if hasStructuralChanges {
            containerView.tableView.reloadData()
        } else {
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
        synchronizeAppKitDropIndicator(actions: listActions)
        recomputeHoveredRow()
        updateDropTargets()
    }

    // MARK: - Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return tableView.rowHeight }
        let listRow = rows[row]
        return rowHeightCache.height(
            for: listRow,
            columnWidth: currentColumnWidth(),
            environment: environment
        ) ?? SidebarWorkspaceTableRowHeightCalculator().estimatedHeight(
            for: listRow,
            globalFontMagnificationPercent: environment.globalFontMagnificationPercent
        )
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if rows[row].isGroupHeader {
            let cell = tableView.makeView(
                withIdentifier: SidebarWorkspaceGroupHeaderCellView.reuseIdentifier,
                owner: self
            ) as? SidebarWorkspaceGroupHeaderCellView ?? SidebarWorkspaceGroupHeaderCellView()
            configure(headerCell: cell, at: row)
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

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let listActions, editingWorkspaceId == nil else { return nil }
        let workspaceId = rows[row].workspaceId
        listActions.beginWorkspaceDrag(workspaceId)
        didBeginDragDuringMouseTracking = true
        isDragSessionActive = true
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
        isDragSessionActive = false
        listActions?.endWorkspaceDrag()
        workspaceDragSessionDidEnd()
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

    // MARK: - Clicks

    func willTrackMouseDown() {
        didBeginDragDuringMouseTracking = false
    }

    func click(row: Int, modifierFlags: NSEvent.ModifierFlags) {
        guard rows.indices.contains(row) else { return }
        switch cellActions(forRow: row) {
        case .workspace(let actions):
            actions.select(modifierFlags)
        case .groupHeader(let actions):
            actions.onFocusAnchor()
        case nil:
            break
        }
    }

    func doubleClick(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch cellActions(forRow: row) {
        case .workspace(let actions):
            actions.select([])
            beginRename(rowId: rows[row].id)
        case .groupHeader, nil:
            break
        }
    }

    func middleClick(row: Int) {
        // Group anchors are excluded, matching the pointer monitor the
        // SwiftUI list used (middle-clicking a header must not close the
        // anchor workspace).
        guard rows.indices.contains(row), !rows[row].isGroupHeader else { return }
        listActions?.closeWorkspace(rows[row].workspaceId)
    }

    func doubleClickEmptyArea() {
        listActions?.createWorkspaceAtEnd()
    }

    func createEmptyWorkspaceGroup() {
        listActions?.createEmptyWorkspaceGroup()
    }

    // MARK: - Inline rename

    func beginRename(rowId: SidebarWorkspaceRenderItemID) {
        guard let index = rowIndexById[rowId],
              rows.indices.contains(index),
              !rows[index].isGroupHeader else {
            return
        }
        setEditingWorkspaceId(rows[index].workspaceId)
    }

    func endRename() {
        setEditingWorkspaceId(nil)
    }

    private func setEditingWorkspaceId(_ next: UUID?) {
        guard editingWorkspaceId != next else { return }
        let previous = editingWorkspaceId
        editingWorkspaceId = next
        let affected = [previous, next].compactMap { id in
            id.map { SidebarWorkspaceRenderItemID.workspace($0) }
        }
        reconfigureRows(withIds: affected)
    }

    // MARK: - Context menus

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

    func menu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let listRow = rows[row]
        let menu: NSMenu?
        switch (listRow.content, cellActions(forRow: row)) {
        case (.workspace(let snapshot), .workspace(let actions)):
            menu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
                snapshot: snapshot,
                actions: actions
            )
        case (.groupHeader(let snapshot), .groupHeader(let actions)):
            menu = SidebarWorkspaceGroupHeaderContextMenuFactory.makeMenu(
                snapshot: snapshot,
                actions: actions
            )
        default:
            menu = nil
        }
        guard let menu else { return nil }
        menu.delegate = self
        openContextMenu = menu
        contextMenuWillOpen(rowId: listRow.id)
        return menu
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            guard menu === openContextMenu else { return }
            openContextMenu = nil
            contextMenuDidClose()
        }
    }

    private func contextMenuWillOpen(rowId: SidebarWorkspaceRenderItemID) {
        contextMenuRowId = rowId
        if let index = rowIndexById[rowId], case .workspace(let actions) = cellActions(forRow: index) {
            actions.onContextMenuAppear()
        }
        reconfigureRows(withIds: [rowId])
    }

    private func contextMenuDidClose() {
        guard let rowId = contextMenuRowId else { return }
        contextMenuRowId = nil
        if let index = rowIndexById[rowId], case .workspace(let actions) = cellActions(forRow: index) {
            actions.onContextMenuDisappear()
        }
        reconfigureRows(withIds: [rowId])
        recomputeHoveredRow()
    }

    // MARK: - Hover

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
        if let changed = rowHeightCache.prepareIfWidthChanged(
            rows: rows,
            columnWidth: currentColumnWidth(),
            environment: environment
        ), !changed.isEmpty {
            containerView?.tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        recomputeHoveredRow()
        updateDropTargets()
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

    // MARK: - Cell configuration

    private func cellActions(forRow row: Int) -> SidebarWorkspaceListCellActions? {
        guard rows.indices.contains(row) else { return nil }
        return actionResolver?(rows[row])
    }

    private func reconfigureRows(withIds ids: [SidebarWorkspaceRenderItemID]) {
        let indexes = IndexSet(ids.compactMap { rowIndexById[$0] })
        reconfigureVisibleRows(indexes)
    }

    private func reconfigureVisibleRows(_ indexes: IndexSet) {
        guard let table = containerView?.tableView else { return }
        for row in indexes where rows.indices.contains(row) {
            let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            if let cell = view as? SidebarWorkspaceTableCellView {
                configure(cell: cell, at: row)
            } else if let cell = view as? SidebarWorkspaceGroupHeaderCellView {
                configure(headerCell: cell, at: row)
            }
        }
    }

    private func configure(cell: SidebarWorkspaceTableCellView, at row: Int) {
        guard case .workspace(let snapshot) = rows[row].content else { return }
        let rowId = rows[row].id
        var actions: SidebarWorkspaceRowActions?
        if case .workspace(let resolved) = cellActions(forRow: row) {
            actions = resolved
        }
#if DEBUG
        reconfigurationProbe?()
#endif
        cell.configure(
            snapshot: snapshot,
            environment: environment,
            isPointerHovering: hoveredRowId == rowId && contextMenuRowId == nil,
            isContextMenuOpen: contextMenuRowId == rowId,
            isEditing: editingWorkspaceId == snapshot.workspaceId,
            actions: actions,
            host: SidebarWorkspaceCellHost(
                endRename: { [weak self] in self?.endRename() }
            )
        )
    }

    private func configure(headerCell cell: SidebarWorkspaceGroupHeaderCellView, at row: Int) {
        guard case .groupHeader(let snapshot) = rows[row].content else { return }
        let rowId = rows[row].id
        var actions: SidebarWorkspaceGroupHeaderActions?
        if case .groupHeader(let resolved) = cellActions(forRow: row) {
            actions = resolved
        }
#if DEBUG
        reconfigurationProbe?()
#endif
        cell.configure(
            snapshot: snapshot,
            environment: environment,
            isPointerHovering: hoveredRowId == rowId && contextMenuRowId == nil,
            isContextMenuOpen: contextMenuRowId == rowId,
            actions: actions
        )
    }

    private func scrollSelectedRowToVisibleIfNeeded() {
        guard let table = containerView?.tableView,
              let selectedScrollTargetWorkspaceId,
              let row = rows.firstIndex(where: {
                  $0.workspaceId == selectedScrollTargetWorkspaceId && !$0.isGroupHeader
              }) ?? rows.firstIndex(where: { $0.workspaceId == selectedScrollTargetWorkspaceId }) else {
            return
        }
        let visibleRect = table.visibleRect
        guard !visibleRect.contains(table.rect(ofRow: row)) else { return }
        table.scrollRowToVisible(row)
    }

    // MARK: - Drop views

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
