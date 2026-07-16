import AppKit
import CmuxAppKitSupportUI
import Foundation

/// Native, reusable workspace-sidebar owner.
///
/// The controller owns only stable render identity, AppKit lifecycle, and
/// interaction routing. Live workspace state stays behind lazy resolvers in
/// ``SidebarAppKitConfiguration`` and is read only when AppKit requests a row.
@MainActor
final class SidebarAppKitViewController: NSViewController {
    private enum Identifier {
        static let column = NSUserInterfaceItemIdentifier("SidebarAppKitColumn")
        static let row = NSUserInterfaceItemIdentifier("SidebarAppKitRow")
        static let workspaceCell = NSUserInterfaceItemIdentifier("SidebarAppKitWorkspaceCell")
        static let groupCell = NSUserInterfaceItemIdentifier("SidebarAppKitGroupCell")
    }

    private enum ItemInput: Equatable {
        case workspace(workspaceID: UUID)
        case group(groupID: UUID, anchorWorkspaceID: UUID)

        init(_ item: SidebarWorkspaceRenderItem) {
            switch item {
            case .workspace(let workspaceID):
                self = .workspace(workspaceID: workspaceID)
            case .groupHeader(let groupID, let anchorWorkspaceID):
                self = .group(groupID: groupID, anchorWorkspaceID: anchorWorkspaceID)
            }
        }

        var renderItem: SidebarWorkspaceRenderItem {
            switch self {
            case .workspace(let workspaceID):
                return .workspace(workspaceId: workspaceID)
            case .group(let groupID, let anchorWorkspaceID):
                return .groupHeader(groupId: groupID, anchorWorkspaceId: anchorWorkspaceID)
            }
        }

        var workspaceID: UUID {
            switch self {
            case .workspace(let workspaceID):
                return workspaceID
            case .group(_, let anchorWorkspaceID):
                return anchorWorkspaceID
            }
        }
    }

    private struct ItemPresentation: Equatable {
        let input: ItemInput
        let isHovered: Bool
    }

    #if DEBUG
    struct ResolverInvocationCounts: Equatable {
        var workspaceSnapshots = 0
        var groupSnapshots = 0
        var workspaceActions = 0
        var groupActions = 0
    }

    private(set) var resolverInvocationCounts = ResolverInvocationCounts()
    #endif

    let tableView = SidebarAppKitTableView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)
    private let clipView = SidebarAppKitClipView(frame: .zero)

    private let headerContainer = NSView(frame: .zero)
    private let contentContainer = NSView(frame: .zero)
    private let footerContainer = NSView(frame: .zero)
    private let trailingBorderView = SidebarAppKitPassiveBorderView(frame: .zero)
    private var borderRefreshObserver: NSObjectProtocol?
    private var installedHeaderView: NSView?
    private var installedContentView: NSView?
    private var installedFooterView: NSView?
    private var configuration: SidebarAppKitConfiguration?
    private var isApplyingSelection = false
    private var lastVisibleWorkspaceIDs: Set<UUID> = []
    private var lastAppliedSelectedWorkspaceIDs: Set<UUID>?
    private var lastActiveWorkspaceID: UUID?
    private var lastActiveRow: Int?
    private var registeredDragTypes: [NSPasteboard.PasteboardType] = []
    private(set) var rowIndexByWorkspaceID: [UUID: Int] = [:]

    private lazy var snapshotStore = SidebarAppKitSnapshotStore<
        SidebarWorkspaceRenderItemID,
        ItemInput,
        ItemPresentation
    >(
        snapshot: SidebarAppKitSnapshot(items: []),
        projector: { _, input, context in
            ItemPresentation(input: input, isHovered: context.isHovered)
        }
    )

    override func loadView() {
        let root = NSView(frame: .zero)
        root.setAccessibilityIdentifier("Sidebar")
        view = root

        let stack = NSStackView(views: [headerContainer, contentContainer, footerContainer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        root.addSubview(stack)
        trailingBorderView.translatesAutoresizingMaskIntoConstraints = false
        trailingBorderView.wantsLayer = true
        root.addSubview(trailingBorderView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            trailingBorderView.topAnchor.constraint(equalTo: root.topAnchor),
            trailingBorderView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            trailingBorderView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            trailingBorderView.widthAnchor.constraint(equalToConstant: 1),
        ])
        contentContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        headerContainer.setContentHuggingPriority(.required, for: .vertical)
        headerContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        headerContainer.isHidden = true
        footerContainer.setContentHuggingPriority(.required, for: .vertical)
        footerContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        footerContainer.isHidden = true

        configureTableView()
        configureScrollView()
        installContentView(scrollView)
        refreshTrailingBorder()
        borderRefreshObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTrailingBorder()
            }
        }
    }

    deinit {
        if let borderRefreshObserver {
            NotificationCenter.default.removeObserver(borderRefreshObserver)
        }
    }

    func apply(_ nextConfiguration: SidebarAppKitConfiguration) {
        loadViewIfNeeded()
        let previousItemIDs = snapshotStore.orderedItemIDs
        configuration = nextConfiguration

        let nextSnapshot = SidebarAppKitSnapshot(
            items: nextConfiguration.renderItems.map { item in
                SidebarAppKitSnapshotItem(id: item.id, input: ItemInput(item))
            }
        )
        let diff = snapshotStore.apply(snapshot: nextSnapshot)
        rebuildWorkspaceIndex()

        let isShowingTable = nextConfiguration.alternateContentView == nil
        let contentChanged = installContentView(
            nextConfiguration.alternateContentView ?? scrollView
        )
        installHeaderView(nextConfiguration.headerView)
        installFooterView(nextConfiguration.footerView)
        applyDragConfiguration(nextConfiguration.dragHandlers)

        let structureChanged = previousItemIDs != snapshotStore.orderedItemIDs
        if structureChanged {
            lastAppliedSelectedWorkspaceIDs = nil
        }
        if isShowingTable {
            if structureChanged || contentChanged {
                tableView.reloadData()
            } else if !diff.reloadedItemIDs.isEmpty {
                reconfigure(itemIDs: diff.reloadedItemIDs)
            } else {
                reconfigureVisibleRows()
            }
            applySelection(nextConfiguration.selectedWorkspaceIDs)
            scrollActiveWorkspaceToVisibleIfNeeded(nextConfiguration.activeWorkspaceID)
            tableView.reconcileHoveredRow()
            publishVisibleWorkspaceIDsIfNeeded()
        } else {
            if !lastVisibleWorkspaceIDs.isEmpty {
                lastVisibleWorkspaceIDs = []
                nextConfiguration.interactions.onVisibleWorkspaceIDsChanged([])
            }
        }
    }

    /// Re-resolves only requested rows that are currently realized or visible.
    /// Structural identity and all unrelated rows remain untouched.
    func reconfigure(itemIDs: Set<SidebarWorkspaceRenderItemID>) {
        guard installedContentView === scrollView, !itemIDs.isEmpty else { return }
        let visibleRows = visibleRowIndexes()
        var rows = IndexSet()
        for itemID in itemIDs {
            guard let row = snapshotStore.rowIndex(for: itemID),
                  visibleRows.contains(row) else { continue }
            rows.insert(row)
        }
        reload(rows: rows)
    }

    /// Updates only native selection and visibility state. This is the hot
    /// path used when an unrelated SwiftUI ancestor re-evaluates the
    /// representable; it deliberately avoids an O(n) structural snapshot diff
    /// and avoids reconfiguring every visible cell.
    func updateSelection(
        selectedWorkspaceIDs: Set<UUID>,
        activeWorkspaceID: UUID?
    ) {
        guard installedContentView === scrollView else { return }
        applySelection(selectedWorkspaceIDs)
        scrollActiveWorkspaceToVisibleIfNeeded(activeWorkspaceID)
    }

    func rowIndex(for itemID: SidebarWorkspaceRenderItemID) -> Int? {
        snapshotStore.rowIndex(for: itemID)
    }

    func checklistAnchorView(for workspaceID: UUID, makeVisible: Bool = true) -> NSView? {
        guard let row = rowIndexByWorkspaceID[workspaceID] else {
            return makeVisible ? scrollView.contentView : nil
        }
        if makeVisible {
            tableView.scrollRowToVisible(row)
            tableView.layoutSubtreeIfNeeded()
        }
        guard let cell = tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: makeVisible
        ) else {
            return nil
        }
        return (cell as? SidebarAppKitWorkspaceCellView)?.checklistPresentationAnchor ?? cell
    }

    @discardableResult
    func focusInlineChecklistAddField(for workspaceID: UUID) -> Bool {
        guard let row = rowIndexByWorkspaceID[workspaceID] else { return false }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? SidebarAppKitWorkspaceCellView else {
            return false
        }
        return cell.focusInlineChecklistAddField()
    }

    func noteChecklistHeightChanged(for workspaceID: UUID) {
        guard let row = rowIndexByWorkspaceID[workspaceID] else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        publishVisibleWorkspaceIDsIfNeeded()
    }

    func prepareForRemoval() {
        if !lastVisibleWorkspaceIDs.isEmpty {
            configuration?.interactions.onVisibleWorkspaceIDsChanged([])
        }
        tableView.onHoveredRowChanged = nil
        tableView.onPrimaryClick = nil
        tableView.onMiddleClick = nil
        tableView.contextMenuProvider = nil
        tableView.onEmptyAreaDoubleClick = nil
        tableView.emptyAreaContextMenuProvider = nil
        clipView.onEmptyAreaDoubleClick = nil
        clipView.emptyAreaContextMenuProvider = nil
        tableView.onVisibleRowsMayHaveChanged = nil
        installedHeaderView?.removeFromSuperview()
        installedHeaderView = nil
        headerContainer.isHidden = true
        configuration = nil
        lastVisibleWorkspaceIDs = []
        tableView.unregisterDraggedTypes()
        registeredDragTypes = []
        if let borderRefreshObserver {
            NotificationCenter.default.removeObserver(borderRefreshObserver)
            self.borderRefreshObserver = nil
        }
    }

    #if DEBUG
    func resetResolverInvocationCounts() {
        resolverInvocationCounts = ResolverInvocationCounts()
    }
    #endif

    private func configureTableView() {
        let column = NSTableColumn(identifier: Identifier.column)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 38
        tableView.usesAutomaticRowHeights = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Sidebar")

        tableView.onHoveredRowChanged = { [weak self] previousRow, nextRow in
            self?.hoveredRowChanged(from: previousRow, to: nextRow)
        }
        tableView.onPrimaryClick = { [weak self] row, event in
            self?.activateRow(row, modifiers: event.modifierFlags)
        }
        tableView.onMiddleClick = { [weak self] row, event in
            self?.handleMiddleClick(row: row, event: event) ?? false
        }
        tableView.contextMenuProvider = { [weak self] row, event in
            self?.contextMenu(row: row, event: event)
        }
        tableView.onEmptyAreaDoubleClick = { [weak self] in
            self?.configuration?.interactions.onEmptyAreaDoubleClick?()
        }
        tableView.emptyAreaContextMenuProvider = { [weak self] event in
            self?.configuration?.interactions.emptyAreaContextMenuProvider?(event)
        }
        clipView.onEmptyAreaDoubleClick = { [weak self] in
            self?.configuration?.interactions.onEmptyAreaDoubleClick?()
        }
        clipView.emptyAreaContextMenuProvider = { [weak self] event in
            self?.configuration?.interactions.emptyAreaContextMenuProvider?(event)
        }
        tableView.onVisibleRowsMayHaveChanged = { [weak self] in
            self?.publishVisibleWorkspaceIDsIfNeeded()
        }
    }

    private func configureScrollView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentView = clipView
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    private func refreshTrailingBorder() {
        let color = WindowChromeColorResolver().separatorColor(
            forChromeBackground: GhosttyBackgroundTheme.currentColor()
        )
        trailingBorderView.layer?.backgroundColor = color
            .usingColorSpace(.deviceRGB)?
            .cgColor
    }

    @discardableResult
    private func installContentView(_ contentView: NSView) -> Bool {
        guard installedContentView !== contentView else { return false }
        installedContentView?.removeFromSuperview()
        installedContentView = contentView
        embed(contentView, in: contentContainer)
        return true
    }

    private func installFooterView(_ footerView: NSView?) {
        guard installedFooterView !== footerView else { return }
        installedFooterView?.removeFromSuperview()
        installedFooterView = footerView
        footerContainer.isHidden = footerView == nil
        if let footerView {
            embed(footerView, in: footerContainer)
        }
    }

    private func installHeaderView(_ headerView: NSView?) {
        guard installedHeaderView !== headerView else { return }
        installedHeaderView?.removeFromSuperview()
        installedHeaderView = headerView
        headerContainer.isHidden = headerView == nil
        if let headerView {
            embed(headerView, in: headerContainer)
        }
    }

    private func embed(_ child: NSView, in container: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func rebuildWorkspaceIndex() {
        var next: [UUID: Int] = [:]
        next.reserveCapacity(snapshotStore.itemCount)
        for row in 0..<snapshotStore.itemCount {
            guard let input = snapshotStore.input(
                for: snapshotStore.itemID(atRow: row)!
            ) else { continue }
            next[input.workspaceID] = row
        }
        rowIndexByWorkspaceID = next
    }

    private func applySelection(_ workspaceIDs: Set<UUID>) {
        guard lastAppliedSelectedWorkspaceIDs != workspaceIDs else { return }
        lastAppliedSelectedWorkspaceIDs = workspaceIDs
        var rows = IndexSet()
        for workspaceID in workspaceIDs {
            if let row = rowIndexByWorkspaceID[workspaceID] {
                rows.insert(row)
            }
        }
        guard rows != tableView.selectedRowIndexes else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func scrollActiveWorkspaceToVisibleIfNeeded(_ workspaceID: UUID?) {
        defer {
            lastActiveWorkspaceID = workspaceID
            lastActiveRow = workspaceID.flatMap { rowIndexByWorkspaceID[$0] }
        }
        guard let workspaceID, let row = rowIndexByWorkspaceID[workspaceID] else { return }
        let rowRect = tableView.rect(ofRow: row)
        let isFullyVisible = tableView.visibleRect.contains(rowRect)
        guard workspaceID != lastActiveWorkspaceID || row != lastActiveRow || !isFullyVisible else {
            return
        }
        tableView.scrollRowToVisible(row)
    }

    private func reconfigureVisibleRows() {
        reload(rows: visibleRowIndexes())
    }

    private func reload(rows: IndexSet) {
        guard !rows.isEmpty, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
        tableView.noteHeightOfRows(withIndexesChanged: rows)
        updateHoveredRowViews(rows: rows)
        publishVisibleWorkspaceIDsIfNeeded()
    }

    private func visibleRowIndexes() -> IndexSet {
        guard tableView.numberOfRows > 0 else { return [] }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let upperBound = min(tableView.numberOfRows, range.location + range.length)
        guard range.location < upperBound else { return [] }
        return IndexSet(integersIn: range.location..<upperBound)
    }

    private func publishVisibleWorkspaceIDsIfNeeded() {
        guard installedContentView === scrollView, let configuration else { return }
        var visibleWorkspaceIDs = Set<UUID>()
        for row in visibleRowIndexes() {
            guard let itemID = snapshotStore.itemID(atRow: row),
                  let input = snapshotStore.input(for: itemID) else { continue }
            visibleWorkspaceIDs.insert(input.workspaceID)
        }
        guard visibleWorkspaceIDs != lastVisibleWorkspaceIDs else { return }
        lastVisibleWorkspaceIDs = visibleWorkspaceIDs
        configuration.interactions.onVisibleWorkspaceIDsChanged(visibleWorkspaceIDs)
    }

    private func hoveredRowChanged(from previousRow: Int?, to nextRow: Int?) {
        let nextItemID = nextRow.flatMap { snapshotStore.itemID(atRow: $0) }
        let diff = snapshotStore.setHoveredItemID(nextItemID)
        updateHoveredRowViews(rows: diff.reloadedRows)
        configuration?.interactions.onHoveredItemChanged(nextItemID)
    }

    private func updateHoveredRowViews(rows: IndexSet) {
        for row in rows {
            guard let rowView = tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) as? SidebarAppKitTableView.RowView else { continue }
            rowView.isPointerHovering = row == tableView.hoveredRow
        }
    }

    private func handleMiddleClick(row: Int, event: NSEvent) -> Bool {
        guard let handler = configuration?.interactions.onMiddleClick,
              let item = renderItem(atRow: row) else { return false }
        handler(item, event)
        return true
    }

    private func activateRow(_ row: Int, modifiers: NSEvent.ModifierFlags) {
        guard let item = renderItem(atRow: row) else { return }
        configuration?.interactions.onSelectionChanged(
            item.rowWorkspaceId,
            modifiers
        )
    }

    private func contextMenu(row: Int, event: NSEvent) -> NSMenu? {
        guard let provider = configuration?.interactions.contextMenuProvider,
              let item = renderItem(atRow: row) else { return nil }
        return provider(item, event)
    }

    private func renderItem(atRow row: Int) -> SidebarWorkspaceRenderItem? {
        guard let itemID = snapshotStore.itemID(atRow: row),
              let input = snapshotStore.input(for: itemID) else { return nil }
        return input.renderItem
    }

    private func applyDragConfiguration(_ handlers: SidebarAppKitConfiguration.DragHandlers?) {
        let nextTypes = handlers?.registeredTypes ?? []
        if registeredDragTypes != nextTypes {
            tableView.unregisterDraggedTypes()
            if !nextTypes.isEmpty {
                tableView.registerForDraggedTypes(nextTypes)
            }
            registeredDragTypes = nextTypes
        }
        tableView.setDraggingSourceOperationMask(
            handlers?.localSourceOperationMask ?? [],
            forLocal: true
        )
        tableView.setDraggingSourceOperationMask(
            handlers?.externalSourceOperationMask ?? [],
            forLocal: false
        )
    }
}

private final class SidebarAppKitPassiveBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension SidebarAppKitViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshotStore.itemCount
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let configuration,
              let itemID = snapshotStore.itemID(atRow: row),
              let input = snapshotStore.input(for: itemID) else { return nil }

        switch input {
        case .workspace(let workspaceID):
            #if DEBUG
            resolverInvocationCounts.workspaceSnapshots += 1
            #endif
            guard let snapshot = configuration.workspaceSnapshot(workspaceID) else { return nil }
            let cell = reusableWorkspaceCell(in: tableView)
            cell.resetForReuse()
            #if DEBUG
            resolverInvocationCounts.workspaceActions += 1
            #endif
            cell.configure(
                snapshot: snapshot,
                actions: configuration.workspaceActions(workspaceID)
            )
            cell.setAccessibilityIdentifier("sidebarWorkspace.\(workspaceID.uuidString)")
            cell.setAccessibilityLabel(String(
                localized: "accessibility.workspacePosition",
                defaultValue: "\(snapshot.workspace.title), workspace \(snapshot.index + 1) of \(snapshot.workspaceCount)"
            ))
            return cell

        case .group(let groupID, _):
            #if DEBUG
            resolverInvocationCounts.groupSnapshots += 1
            #endif
            guard let snapshot = configuration.groupSnapshot(groupID) else { return nil }
            let cell = reusableGroupCell(in: tableView)
            cell.resetForReuse()
            #if DEBUG
            resolverInvocationCounts.groupActions += 1
            #endif
            cell.configure(
                snapshot: snapshot,
                actions: configuration.groupActions(groupID)
            )
            cell.setAccessibilityIdentifier("sidebarWorkspaceGroup.\(groupID.uuidString)")
            cell.setAccessibilityLabel(snapshot.name)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView: SidebarAppKitTableView.RowView
        if let reusable = tableView.makeView(
            withIdentifier: Identifier.row,
            owner: nil
        ) as? SidebarAppKitTableView.RowView {
            rowView = reusable
        } else {
            rowView = SidebarAppKitTableView.RowView(frame: .zero)
            rowView.identifier = Identifier.row
        }
        rowView.isPointerHovering = row == self.tableView.hoveredRow
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection,
              !tableView.isHandlingPointerSelection,
              let configuration else {
            return
        }
        let primaryWorkspaceID = tableView.selectedRow >= 0
            ? renderItem(atRow: tableView.selectedRow)?.rowWorkspaceId
            : nil
        configuration.interactions.onSelectionChanged(
            primaryWorkspaceID,
            self.tableView.lastSelectionModifierFlags
        )
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let handlers = configuration?.dragHandlers,
              let item = renderItem(atRow: row) else { return nil }
        return handlers.pasteboardWriter(item)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let handlers = configuration?.dragHandlers else { return [] }
        return handlers.validateDrop(
            info,
            renderItem(atRow: row),
            row,
            dropOperation
        )
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let handlers = configuration?.dragHandlers else { return false }
        return handlers.acceptDrop(
            info,
            renderItem(atRow: row),
            row,
            dropOperation
        )
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        guard let handler = configuration?.dragHandlers?.dragSessionBegan else { return }
        handler(session, rowIndexes.compactMap { snapshotStore.itemID(atRow: $0) })
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        configuration?.dragHandlers?.dragSessionEnded?(session, screenPoint, operation)
    }

    func tableView(
        _ tableView: NSTableView,
        updateDraggingItemsForDrag draggingInfo: NSDraggingInfo
    ) {
        configuration?.dragHandlers?.updateDraggingItems?(draggingInfo)
    }

    private func reusableWorkspaceCell(in tableView: NSTableView) -> SidebarAppKitWorkspaceCellView {
        if let reusable = tableView.makeView(
            withIdentifier: Identifier.workspaceCell,
            owner: nil
        ) as? SidebarAppKitWorkspaceCellView {
            return reusable
        }
        return SidebarAppKitWorkspaceCellView(identifier: Identifier.workspaceCell)
    }

    private func reusableGroupCell(in tableView: NSTableView) -> SidebarAppKitGroupCellView {
        if let reusable = tableView.makeView(
            withIdentifier: Identifier.groupCell,
            owner: nil
        ) as? SidebarAppKitGroupCellView {
            return reusable
        }
        return SidebarAppKitGroupCellView(identifier: Identifier.groupCell)
    }
}
