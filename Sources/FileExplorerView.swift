import AppKit
import Bonsplit
import Combine
import CmuxFoundation
import CmuxWorkspaces
import CmuxSettings
import SwiftUI

#if DEBUG
private func fileExplorerDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

// MARK: - File Explorer Panel (single NSViewRepresentable)

/// The entire file explorer panel as one AppKit view hierarchy.
/// Contains the header bar (path + controls) and NSOutlineView, with no SwiftUI intermediaries.
struct FileExplorerPanelView: NSViewRepresentable {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    let onOpenFilePreview: (String) -> Void
    var presentation: FileExplorerPanelPresentation = .files
    var placement: FileExplorerPanelPlacement = .rightSidebar
    var onFocus: (() -> Void)?
    var onContainerChange: ((FileExplorerContainerView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: onOpenFilePreview,
            placement: placement,
            onFocus: onFocus,
            onContainerChange: onContainerChange
        )
    }

    func makeNSView(context: Context) -> FileExplorerContainerView {
        let container = FileExplorerContainerView(coordinator: context.coordinator, presentation: presentation)
        context.coordinator.containerView = container
        context.coordinator.onContainerChange?(container)
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        context.coordinator.store = store
        context.coordinator.state = state
        context.coordinator.onOpenFilePreview = onOpenFilePreview
        context.coordinator.placement = placement
        context.coordinator.onFocus = onFocus
        context.coordinator.onContainerChange = onContainerChange
        context.coordinator.onContainerChange?(container)
        container.updateShortcutPlacement(placement)
        container.updateHeader(store: store)
        container.updatePresentation(presentation)
        context.coordinator.reloadIfNeeded()
        container.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: FileExplorerContainerView, coordinator: Coordinator) {
        _ = nsView
        coordinator.onContainerChange?(nil)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var store: FileExplorerStore
        var state: FileExplorerState
        var onOpenFilePreview: (String) -> Void
        var placement: FileExplorerPanelPlacement
        var onFocus: (() -> Void)?
        var onContainerChange: ((FileExplorerContainerView?) -> Void)?
        weak var containerView: FileExplorerContainerView?
        weak var outlineView: NSOutlineView?
        private var lastRootNodeCount: Int = -1
        private var observationCancellable: AnyCancellable?
        private var styleObserver: Any?
        private var isUpdatingOutlineProgrammatically = false
        private var fileFilter = FileExplorerTreeFilter()
        private var preFilterTopVisiblePath: String?

        init(
            store: FileExplorerStore,
            state: FileExplorerState,
            onOpenFilePreview: @escaping (String) -> Void,
            placement: FileExplorerPanelPlacement = .rightSidebar,
            onFocus: (() -> Void)? = nil,
            onContainerChange: ((FileExplorerContainerView?) -> Void)? = nil
        ) {
            self.store = store
            self.state = state
            self.onOpenFilePreview = onOpenFilePreview
            self.placement = placement
            self.onFocus = onFocus
            self.onContainerChange = onContainerChange
            super.init()
            observeStore()
            styleObserver = NotificationCenter.default.addObserver(
                forName: .fileExplorerStyleDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let outlineView = self.outlineView else { return }
                let style = FileExplorerStyle.current
                self.withProgrammaticOutlineUpdate {
                    outlineView.indentationPerLevel = style.indentation
                    outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<outlineView.numberOfRows))
                    outlineView.reloadData()
                    self.restoreExpansionState(self.store.expandedPaths, in: outlineView)
                    self.applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
                }
            }
        }

        @MainActor
        @discardableResult
        func handleModeShortcut(_ mode: RightSidebarMode, in window: NSWindow?) -> Bool {
            guard placement == .rightSidebar else { return false }
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return true
        }

        @MainActor
        func noteKeyboardFocus(mode: RightSidebarMode, in window: NSWindow?) {
            switch placement {
            case .rightSidebar:
                state.mode = mode
                guard let window else { return }
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: mode, in: window)
            case .pane:
                onFocus?()
            }
        }

        deinit {
            if let observer = styleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func observeStore() {
            observationCancellable = store.objectWillChange
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reloadIfNeeded()
                    }
                }
        }

        @MainActor
        func reloadIfNeeded() {
            guard let outlineView else { return }

            // Update empty state vs tree visibility
            containerView?.updateVisibility(
                hasContent: !store.rootPath.isEmpty,
                isLoading: store.isRootLoading,
                statusMessage: store.rootStatusMessage
            )

            if fileFilter.isActive {
                fileFilter.rebuild(nodes: store.rootNodes)
                reloadFilteredTree(in: outlineView)
                return
            }

            let newCount = store.rootNodes.count
            withProgrammaticOutlineUpdate {
                if newCount != lastRootNodeCount {
                    lastRootNodeCount = newCount
                    let expandedPaths = store.expandedPaths
                    outlineView.reloadData()
                    restoreExpansionState(expandedPaths, in: outlineView)
                } else {
                    refreshLoadedNodes(in: outlineView)
                }
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
            }
        }

        private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
            var row = 0
            while row < outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileExplorerNode,
                   expandedPaths.contains(node.path), outlineView.isExpandable(node) {
                    outlineView.expandItem(node)
                }
                row += 1
            }
        }

        private func refreshLoadedNodes(in outlineView: NSOutlineView) {
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.isDirectory {
                    let isCurrentlyExpanded = outlineView.isItemExpanded(node)
                    let shouldBeExpanded = store.expandedPaths.contains(node.path)

                    if shouldBeExpanded && !isCurrentlyExpanded && node.children != nil {
                        outlineView.reloadItem(node, reloadChildren: true)
                        outlineView.expandItem(node)
                    } else if !shouldBeExpanded && isCurrentlyExpanded {
                        outlineView.collapseItem(node)
                    } else if node.children != nil {
                        outlineView.reloadItem(node, reloadChildren: true)
                        if shouldBeExpanded {
                            outlineView.expandItem(node)
                        }
                    }
                }
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return fileFilter.visibleRootNodes(in: store.rootNodes).count
            }
            guard let node = item as? FileExplorerNode else { return 0 }
            return fileFilter.visibleChildren(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return fileFilter.visibleRootNodes(in: store.rootNodes)[index]
            }
            guard let node = item as? FileExplorerNode else {
                return FileExplorerNode(name: "", path: "", isDirectory: false)
            }
            return fileFilter.visibleChildren(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            if fileFilter.isActive { return fileFilter.hasVisibleChildren(node) }
            return node.isExpandable
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileExplorerNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
            let cellView: FileExplorerCellView
            if let existing = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerCellView {
                cellView = existing
            } else {
                cellView = FileExplorerCellView(identifier: identifier)
            }

            let gitStatus = store.gitStatusByPath[node.path]
            cellView.configure(with: node, gitStatus: gitStatus)
            cellView.onHover = { [weak self] isHovering in
                guard let self else { return }
                if isHovering {
                    self.store.prefetchChildren(for: node)
                } else {
                    self.store.cancelPrefetch(for: node)
                }
            }

            return cellView
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode, node.isDirectory else { return false }
            if fileFilter.isActive { return fileFilter.hasVisibleChildren(node) }
            store.expand(node: node)
            return node.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            if fileFilter.isActive { return true }
            store.collapse(node: node)
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingOutlineProgrammatically,
                  let outlineView = notification.object as? NSOutlineView else {
                return
            }
            let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            guard !nodes.isEmpty else { store.select(node: nil); return }
            let anchor = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode : nil
            store.select(nodes: nodes, anchor: anchor ?? nodes.first)
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !fileFilter.isActive else { return }
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            if !store.isExpanded(node) {
                store.expand(node: node)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !fileFilter.isActive else { return }
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            if store.isExpanded(node) {
                store.collapse(node: node)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            FileExplorerRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            FileExplorerStyle.current.rowHeight
        }

        // MARK: - Path-Owned Navigation

        func ensureSelection(in outlineView: NSOutlineView, fallbackToFirstVisible: Bool, scroll: Bool) {
            withProgrammaticOutlineUpdate {
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: fallbackToFirstVisible, scroll: scroll)
            }
        }

        func moveSelection(in outlineView: NSOutlineView, by delta: Int) {
            guard outlineView.numberOfRows > 0 else {
                store.select(node: nil)
                return
            }
            let currentRow = resolvedSelectionRow(in: outlineView) ?? (delta >= 0 ? -1 : outlineView.numberOfRows)
            let targetRow = min(max(currentRow + delta, 0), outlineView.numberOfRows - 1)
            selectRow(targetRow, in: outlineView, scroll: true)
        }

        func performDisclosureAction(
            _ action: RightSidebarKeyboardNavigation.DisclosureAction,
            in outlineView: NSOutlineView
        ) {
            switch action {
            case .collapse:
                collapseSelectedItemOrMoveToParent(in: outlineView)
            case .expand:
                expandSelectedItemOrMoveToChild(in: outlineView)
            }
        }

        func setFileFilterQuery(_ query: String, in outlineView: NSOutlineView) {
            let wasActive = fileFilter.isActive
            if !wasActive, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preFilterTopVisiblePath = topVisibleNode(in: outlineView)?.path
            }
            guard fileFilter.update(query: query, nodes: store.rootNodes) else { return }
            reloadFilteredTree(in: outlineView)
            if wasActive, !fileFilter.isActive {
                restorePreFilterScroll(in: outlineView)
            }
        }

        var isFileFilterActive: Bool { fileFilter.isActive }

        private func reloadFilteredTree(in outlineView: NSOutlineView) {
            withProgrammaticOutlineUpdate {
                outlineView.reloadData()
                if fileFilter.isActive {
                    var row = 0
                    while row < outlineView.numberOfRows {
                        if let node = outlineView.item(atRow: row) as? FileExplorerNode,
                           fileFilter.hasVisibleChildren(node) {
                            outlineView.expandItem(node)
                        }
                        row += 1
                    }
                } else {
                    restoreExpansionState(store.expandedPaths, in: outlineView)
                }
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: fileFilter.isActive, scroll: false)
            }
        }

        private func topVisibleNode(in outlineView: NSOutlineView) -> FileExplorerNode? {
            let rows = outlineView.rows(in: outlineView.visibleRect)
            guard rows.location != NSNotFound, rows.location < outlineView.numberOfRows else { return nil }
            return outlineView.item(atRow: rows.location) as? FileExplorerNode
        }

        private func restorePreFilterScroll(in outlineView: NSOutlineView) {
            defer { preFilterTopVisiblePath = nil }
            guard let path = preFilterTopVisiblePath,
                  let row = (0..<outlineView.numberOfRows).first(where: {
                      (outlineView.item(atRow: $0) as? FileExplorerNode)?.path == path
                  }) else { return }
            outlineView.scrollRowToVisible(row)
        }

        @MainActor func openSelectedItem(in outlineView: NSOutlineView) { openNode(in: outlineView, at: outlineView.selectedRow) }

        private func expandSelectedItemOrMoveToChild(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode,
                  node.isDirectory else {
                return
            }

            selectRow(row, in: outlineView, scroll: true)

            if !store.isExpanded(node) {
                outlineView.expandItem(node)
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: true)
                return
            }

            guard node.children != nil else {
                store.requestDescendIntoFirstChild(of: node)
                return
            }

            if !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            }
            selectFirstChild(of: node, in: outlineView)
        }

        private func collapseSelectedItemOrMoveToParent(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode else {
                return
            }

            if node.isDirectory, outlineView.isItemExpanded(node) || store.isExpanded(node) {
                if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else {
                    store.collapse(node: node)
                }
                selectRow(row, in: outlineView, scroll: true)
                return
            }

            selectParent(of: node, in: outlineView)
        }

        private func selectFirstChild(of node: FileExplorerNode, in outlineView: NSOutlineView) {
            let parentRow = outlineView.row(forItem: node)
            let childRow = parentRow + 1
            guard parentRow >= 0,
                  childRow < outlineView.numberOfRows,
                  let child = outlineView.item(atRow: childRow) as? FileExplorerNode,
                  (outlineView.parent(forItem: child) as? FileExplorerNode) === node else {
                return
            }
            selectRow(childRow, in: outlineView, scroll: true)
        }

        private func selectParent(of node: FileExplorerNode, in outlineView: NSOutlineView) {
            guard let parentNode = outlineView.parent(forItem: node) as? FileExplorerNode else {
                return
            }
            let parentRow = outlineView.row(forItem: parentNode)
            guard parentRow >= 0 else { return }
            selectRow(parentRow, in: outlineView, scroll: true)
        }

        private func applyStoredSelection(
            in outlineView: NSOutlineView,
            fallbackToFirstVisible: Bool,
            scroll: Bool
        ) {
            let exactRows = store.selectedPaths.reduce(into: IndexSet()) { if let resolution = selectionResolution(for: $1, in: outlineView), resolution.isExact { $0.insert(resolution.row) } }
            if !exactRows.isEmpty {
                withProgrammaticOutlineUpdate { outlineView.selectRowIndexes(exactRows, byExtendingSelection: false) }
                let anchorRow = store.selectedPath.flatMap { selectionResolution(for: $0, in: outlineView)?.row }
                if scroll, let row = FileExplorerSelectionRestoration.scrollRow(anchorRow: anchorRow, exactRows: exactRows) { outlineView.scrollRowToVisible(row) }; return
            }
            if let selectedPath = store.selectedPath,
               let resolution = selectionResolution(for: selectedPath, in: outlineView) {
                selectRow(
                    resolution.row,
                    in: outlineView,
                    scroll: scroll,
                    updateStore: resolution.isExact
                )
                return
            }
            guard fallbackToFirstVisible, outlineView.numberOfRows > 0 else { return }
            selectRow(0, in: outlineView, scroll: scroll)
        }

        func resolvedSelectionRow(in outlineView: NSOutlineView) -> Int? {
            if let selectedPath = store.selectedPath,
               let resolution = selectionResolution(for: selectedPath, in: outlineView) {
                return resolution.row
            }
            guard outlineView.selectedRow >= 0,
                  outlineView.selectedRow < outlineView.numberOfRows,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode else {
                return nil
            }
            store.select(node: node)
            return outlineView.selectedRow
        }

        private struct SelectionResolution {
            let row: Int
            let isExact: Bool
        }
        private func selectionResolution(for path: String, in outlineView: NSOutlineView) -> SelectionResolution? {
            var bestAncestor: (row: Int, pathLength: Int)?
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.path == path {
                    return SelectionResolution(row: row, isExact: true)
                }
                if Self.path(node.path, isAncestorOf: path) {
                    let length = node.path.count
                    if bestAncestor == nil || length > bestAncestor!.pathLength {
                        bestAncestor = (row, length)
                    }
                }
            }
            guard let bestAncestor else { return nil }
            return SelectionResolution(row: bestAncestor.row, isExact: false)
        }

        private func selectRow(
            _ row: Int,
            in outlineView: NSOutlineView,
            scroll: Bool,
            updateStore: Bool = true
        ) {
            guard row >= 0, row < outlineView.numberOfRows else { return }
            let node = outlineView.item(atRow: row) as? FileExplorerNode
            withProgrammaticOutlineUpdate {
                if updateStore {
                    store.select(node: node)
                }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if scroll {
                    outlineView.scrollRowToVisible(row)
                }
            }
        }

        private func withProgrammaticOutlineUpdate(_ body: () -> Void) {
            let wasUpdating = isUpdatingOutlineProgrammatically
            isUpdatingOutlineProgrammatically = true
            defer { isUpdatingOutlineProgrammatically = wasUpdating }
            body()
        }

        private static func path(_ ancestor: String, isAncestorOf descendant: String) -> Bool {
            guard ancestor != descendant else { return false }
            if ancestor == "/" {
                return descendant.hasPrefix("/")
            }
            return descendant.hasPrefix(ancestor + "/")
        }

        // MARK: - Drag-to-Preview

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? FileExplorerNode, !node.isDirectory else { return nil }
            guard store.provider is LocalFileExplorerProvider else { return nil }
            return FilePreviewDragPasteboardWriter(filePath: node.path, displayTitle: node.name)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: NSPasteboard(name: .drag))
        }

        @MainActor
        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            openNode(in: sender, at: row)
        }

        // MARK: - Context Menu (NSMenuDelegate)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let clickedRow = outlineView.clickedRow
            guard clickedRow >= 0,
                  let node = outlineView.item(atRow: clickedRow) as? FileExplorerNode else { return }

            let isLocal = store.provider is LocalFileExplorerProvider

            if !node.isDirectory && isLocal {
                FileExplorerExternalOpenMenuItems(
                    fileURL: URL(fileURLWithPath: node.path),
                    target: self,
                    action: #selector(contextMenuOpenExternally(_:))
                ).add(to: menu)
            }

            if isLocal {
                let revealItem = NSMenuItem(
                    title: FileExternalOpenText.revealInFinder,
                    action: #selector(contextMenuRevealInFinder(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = node
                menu.addItem(revealItem)

                menu.addItem(.separator())
            }

            menu.addFileExplorerInsertPathItems(target: self, representedObject: node, insertAction: #selector(contextMenuInsertPath(_:)), insertRelativeAction: #selector(contextMenuInsertRelativePath(_:)))

            let copyPathItem = NSMenuItem(
                title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
                action: #selector(contextMenuCopyPath(_:)),
                keyEquivalent: ""
            )
            copyPathItem.target = self
            copyPathItem.representedObject = node
            menu.addItem(copyPathItem)

            let copyRelItem = NSMenuItem(
                title: String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
                action: #selector(contextMenuCopyRelativePath(_:)),
                keyEquivalent: ""
            )
            copyRelItem.target = self
            copyRelItem.representedObject = node
            menu.addItem(copyRelItem)
        }

        @objc private func contextMenuOpenExternally(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
            FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
        }

        @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            FileExternalOpenAction.revealInFinder(fileURL: URL(fileURLWithPath: node.path))
        }

        @objc private func contextMenuCopyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }

        @objc private func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            let relativePath = FileExplorerTerminalPathInsertion.relativePath(for: node.path, rootPath: store.rootPath)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(relativePath, forType: .string)
        }
    }
}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and outline view.
@MainActor
final class FileExplorerContainerView: NSView {
    private let headerView: FileExplorerHeaderView
    private let searchBarView: FileExplorerSearchBarView
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    private let searchScrollView: NSScrollView
    let searchResultsView: FileExplorerSearchResultsTableView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private let searchController: any FileSearchControlling
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private(set) var searchSnapshot = FileSearchSnapshot.empty
    private(set) var displayedSearchScope: FileExplorerSearchScope
    private var queryState = FileExplorerSearchQueryState()
    private var fileQuickSearchQuery: String?
    private var currentRootPath = ""
    private var currentProviderIsLocal = false
    private var currentWorkspaceRootIdentity: UUID?
    private var currentContentRevision = 0
    private var currentIsLoading = false
    private var currentStatusMessage: String?
    private let searchDebounceSubject = PassthroughSubject<Int, Never>()
    private var searchDebounceCancellable: AnyCancellable?
    private var searchDebounceGeneration = 0
    private let fileFilterDebounceSubject = PassthroughSubject<Int, Never>()
    private var fileFilterDebounceCancellable: AnyCancellable?
    private var fileFilterDebounceGeneration = 0
    private var pendingSearchRefreshAfterSettled = false
    private var preservedSearchNeedsRefresh = false
    private var presentation: FileExplorerPanelPresentation
    let coordinator: FileExplorerPanelView.Coordinator
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private let searchDebounceDelayMilliseconds = 200
    var searchField: FileExplorerSearchField { searchBarView.searchField }
    var searchStatusLabel: NSTextField { searchBarView.statusLabel }
    private var activeBarVisibleHeight: CGFloat { searchBarView.preferredHeight }
    private var hasContentsQuery: Bool {
        !queryState.contentsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
#if DEBUG
    private var debugLastSearchTextChangeUptime: TimeInterval = 0
    private var debugLastSearchLayoutFieldWidth: CGFloat = -1
    private var debugLastSearchLayoutStatusWidth: CGFloat = -1
    private var debugLastLoggedSearchResultCount = -1
    private var debugLastLoggedSearchStatus = ""
#endif
    init(
        coordinator: FileExplorerPanelView.Coordinator,
        presentation: FileExplorerPanelPresentation,
        searchController: (any FileSearchControlling)? = nil
    ) {
        headerView = FileExplorerHeaderView()
        searchBarView = FileExplorerSearchBarView()
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        searchScrollView = NSScrollView()
        searchResultsView = FileExplorerSearchResultsTableView()
        emptyLabel = NSTextField(labelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.searchController = searchController ?? FileSearchController()
        self.presentation = presentation
        self.displayedSearchScope = FileExplorerSearchScope(mode: presentation.rightSidebarMode)
        self.coordinator = coordinator
        super.init(frame: .zero)
        searchBarView.apply(query: queryState.contentsQuery)
        updateShortcutPlacement(coordinator.placement)
        configureSearchDebounce()
        configureFileFilterDebounce()
        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)
        // Search bar
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.isHidden = true
        addSubview(searchBarView)
        searchField.delegate = self
        searchField.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSelectionFromSearchField(by: delta)
        }
        searchField.onCommit = { [weak self] in
            self?.commitSearchFieldSelection()
        }
        searchField.onFocus = { [weak self] in
            guard let self else { return }
            self.coordinator.noteKeyboardFocus(mode: .find, in: self.window)
            self.updateSearchLayout()
            self.resumePreservedSearchIfNeeded()
        }
        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        // Loading indicator
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)
        applyChromeFonts()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyChromeFonts()
            self?.outlineView.reloadData()
            self?.searchResultsView.rowHeight = FileExplorerSearchResultCellView.preferredRowHeight
            self?.searchResultsView.reloadData()
        }
        // Outline view setup
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = FileExplorerStyle.current.indentation
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.onQuickSearchChanged = { [weak self] query in
            guard let self else { return }
            self.fileQuickSearchQuery = query
            self.queryState.setQuery(query ?? "", for: .names)
            if self.displayedSearchScope == .names {
                self.headerView.updateQuickSearch(query: query)
            }
            if query?.isEmpty == false {
                self.scheduleFileFilterRefresh()
            } else {
                self.applyPendingFileFilter()
            }
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(FileExplorerPanelView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        coordinator.outlineView = outlineView
        // Context menu
        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu
        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        addSubview(scrollView)
        // Streaming search results
        searchResultsView.headerView = nil
        searchResultsView.usesAlternatingRowBackgroundColors = false
        searchResultsView.style = .plain
        searchResultsView.selectionHighlightStyle = .regular
        searchResultsView.backgroundColor = .clear
        searchResultsView.rowHeight = FileExplorerSearchResultCellView.preferredRowHeight
        searchResultsView.allowsMultipleSelection = true
        searchResultsView.intercellSpacing = NSSize(width: 0, height: 0)
        searchResultsView.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchResultsView.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: false)
        }
        searchResultsView.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchResultsView.onFocus = { [weak self] in
            guard let self else { return }
            self.coordinator.noteKeyboardFocus(mode: .find, in: self.window)
        }
        searchResultsView.onModeShortcut = { [weak coordinator] mode, window in
            coordinator?.handleModeShortcut(mode, in: window) ?? false
        }
        let searchColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchResult"))
        searchColumn.isEditable = false
        searchColumn.resizingMask = .autoresizingMask
        searchResultsView.addTableColumn(searchColumn)
        searchResultsView.dataSource = self
        searchResultsView.delegate = self
        searchResultsView.target = self
        searchResultsView.doubleAction = #selector(openSelectedSearchResultFromTable(_:))
        searchResultsView.setDraggingSourceOperationMask(.move, forLocal: true)
        let searchMenu = NSMenu()
        searchMenu.delegate = self
        searchResultsView.menu = searchMenu

        searchScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchScrollView.hasVerticalScroller = true
        searchScrollView.hasHorizontalScroller = false
        searchScrollView.horizontalScrollElasticity = .none
        searchScrollView.autohidesScrollers = true
        searchScrollView.borderType = .noBorder
        searchScrollView.drawsBackground = false
        searchScrollView.documentView = searchResultsView
        searchScrollView.isHidden = true
        addSubview(searchScrollView)
        self.searchController.onSnapshotChanged = { [weak self] snapshot in
            self?.applySearchSnapshot(snapshot)
        }
        searchBarHeightConstraint = searchBarView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchBarView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            searchBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBarHeightConstraint,
            scrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchScrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            searchScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func applyChromeFonts() {
        searchBarView.applyFonts()
        emptyLabel.font = GlobalFontMagnification.systemFont(ofSize: 13)
        if !searchBarView.isHidden {
            searchBarHeightConstraint?.constant = activeBarVisibleHeight
        }
        headerView.applyFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingSearchRefresh()
            cancelPendingFileFilterRefresh()
            searchController.cancel(clear: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if coordinator.placement == .rightSidebar {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
        }
#if DEBUG
        dlog(
            "file.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard coordinator.placement == .rightSidebar else { return }
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
    }

    override func layout() {
#if DEBUG
        let debugLayoutStart = ProcessInfo.processInfo.systemUptime
#endif
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        logSearchLayoutIfNeeded(startedAt: debugLayoutStart, reason: "layout")
#endif
    }

    func updateHeader(store: FileExplorerStore) {
        let nextRootPath = store.rootPath, nextProviderIsLocal = store.provider is LocalFileExplorerProvider
        let nextWorkspaceRootIdentity = store.workspaceRootIdentity, nextContentRevision = store.contentRevision
        let workspaceRootChanged = nextWorkspaceRootIdentity != currentWorkspaceRootIdentity, contentRevisionChanged = nextContentRevision != currentContentRevision
        let searchScopeChanged = workspaceRootChanged || nextRootPath != currentRootPath || nextProviderIsLocal != currentProviderIsLocal
        currentRootPath = nextRootPath; currentProviderIsLocal = nextProviderIsLocal
        currentWorkspaceRootIdentity = nextWorkspaceRootIdentity; currentContentRevision = nextContentRevision
        headerView.update(displayPath: store.displayRootPath)
        if workspaceRootChanged {
            cancelPendingSearchRefresh()
            cancelPendingFileFilterRefresh()
            pendingSearchRefreshAfterSettled = false
            searchController.cancel(clear: true)
            outlineView.endQuickSearch()
            fileQuickSearchQuery = nil
            queryState.clearQueries()
            searchBarView.apply(query: queryState.contentsQuery)
            coordinator.setFileFilterQuery("", in: outlineView)
            headerView.updateQuickSearch(query: nil)
            applySearchSnapshot(.empty)
        }
        if searchScopeChanged {
            pendingSearchRefreshAfterSettled = false
            refreshSearchIfNeeded()
        } else if contentRevisionChanged {
            refreshSearchAfterContentRevisionIfNeeded()
        }
    }
    func representedRightSidebarMode() -> RightSidebarMode {
        presentation.rightSidebarMode
    }

    func updateShortcutPlacement(_ placement: FileExplorerPanelPlacement) {
        searchField.fileExplorerPanelPlacement = placement
        outlineView.fileExplorerPanelPlacement = placement
        searchResultsView.fileExplorerPanelPlacement = placement
    }

    func searchQuery(for scope: FileExplorerSearchScope) -> String {
        queryState.query(for: scope)
    }

    private func captureDisplayedQuery() {
        guard displayedSearchScope == .contents else { return }
        queryState.setQuery(searchField.stringValue, for: .contents)
    }

    private func setDisplayedSearchScope(_ scope: FileExplorerSearchScope) {
        captureDisplayedQuery()
        let previousScope = displayedSearchScope
        if previousScope == .names, scope != .names { cancelPendingFileFilterRefresh() }
        if previousScope == .contents, scope != .contents {
            pauseSearchPreservingState()
        }
        displayedSearchScope = scope
        if scope == .contents {
            searchBarView.apply(query: queryState.contentsQuery)
        }
        headerView.updateQuickSearch(query: scope == .names ? fileQuickSearchQuery : nil)
        if scope == .names, previousScope != .names {
            coordinator.setFileFilterQuery(queryState.namesQuery, in: outlineView)
        }
        updateVisibility(
            hasContent: !currentRootPath.isEmpty,
            isLoading: currentIsLoading,
            statusMessage: currentStatusMessage
        )
        if previousScope != .contents, scope == .contents {
            resumePreservedSearchIfNeeded()
        }
    }

    func searchFieldTextDidChange() {
        guard displayedSearchScope == .contents else { return }
        queryState.setQuery(searchField.stringValue, for: .contents)
        if coordinator.state.mode != .find {
            coordinator.noteKeyboardFocus(mode: .find, in: window)
        }
        scrollSearchFieldEditorToInsertionPoint()
        Task { @MainActor [weak self] in
            self?.scrollSearchFieldEditorToInsertionPoint()
        }
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let gapMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        debugLastSearchTextChangeUptime = now
        dlog(
            "file.search.input.changed scope=\(displayedSearchScope) queryLen=\(searchField.stringValue.count) " +
            "gapMs=\(gapMs) results=\(searchSnapshot.results.count) " +
            "status=\(debugSearchStatusName(searchSnapshot.status))"
        )
#endif
        if !hasContentsQuery {
            cancelPendingSearchRefresh()
            pendingSearchRefreshAfterSettled = false
            searchController.cancel(clear: true)
            applySearchSnapshot(.empty)
            updateVisibility(
                hasContent: !currentRootPath.isEmpty,
                isLoading: currentIsLoading,
                statusMessage: currentStatusMessage
            )
            return
        }
        scheduleSearchRefresh()
    }

    func handleSearchFieldCommand(_ commandSelector: Selector, textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitSearchFieldSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearchAndFocusOutline()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelectionFromSearchField(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelectionFromSearchField(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelectionFromSearchField(by delta: Int) {
        moveSearchSelection(by: delta, focusResults: true)
    }

    private func commitSearchFieldSelection() {
        openSelectedSearchResult()
    }

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        let presentationChanged = presentation != nextPresentation
        presentation = nextPresentation
        let activationMode: RightSidebarMode
        if presentation == .unified {
            activationMode = window?.firstResponder.flatMap(rightSidebarActivationMode(owning:))
                ?? coordinator.state.mode
        } else {
            activationMode = presentation.rightSidebarMode
        }
        setDisplayedSearchScope(FileExplorerSearchScope(mode: activationMode))
        if presentationChanged { registerWithKeyboardFocusCoordinatorIfNeeded() }
    }
    func updateVisibility(hasContent: Bool, isLoading: Bool, statusMessage: String?) {
        currentIsLoading = isLoading
        currentStatusMessage = statusMessage
        let normalizedStatus = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStatus = normalizedStatus?.isEmpty == false
        let canShowTree = hasContent && !hasStatus
        applyHidden(headerView, !hasContent && !hasStatus)
        updateSearchLayout(hasContent: canShowTree, isLoading: isLoading)
        let searchCanShow = displayedSearchScope == .contents && canShowTree && !isLoading
        let nextEmptyText = hasStatus
            ? normalizedStatus!
            : String(localized: "fileExplorer.empty", defaultValue: "No folder open")
        if emptyLabel.stringValue != nextEmptyText {
            emptyLabel.stringValue = nextEmptyText
        }
        applyHidden(emptyLabel, canShowTree || searchCanShow || isLoading)
        // Toggle the spinner only when the loading state actually changes.
        if applyHidden(loadingIndicator, !isLoading) {
            if isLoading {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }
        }
    }

    @discardableResult
    func focusSearchField() -> Bool {
        guard let window, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.search.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        setDisplayedSearchScope(.contents)
        let result = window.makeFirstResponder(searchField)
        searchField.selectText(nil)
#if DEBUG
        dlog(
            "file.focus.search.end result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "queryLen=\(searchField.stringValue.count) fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }

    @discardableResult
    func focusOutline() -> Bool {
#if DEBUG
        dlog(
            "file.focus.outline.begin win=\(window?.windowNumber ?? -1) " +
            "canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "hostHidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) scrollHidden=\(scrollView.isHidden ? 1 : 0) " +
            "outlineHidden=\(outlineView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        guard let window, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.outline.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        setDisplayedSearchScope(.names)
        (outlineView.dataSource as? FileExplorerPanelView.Coordinator)?
            .ensureSelection(in: outlineView, fallbackToFirstVisible: true, scroll: true)
        let result = window.makeFirstResponder(outlineView)
#if DEBUG
        dlog(
            "file.focus.outline.end result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        rightSidebarActivationMode(owning: responder) != nil
    }
    func rightSidebarActivationMode(owning responder: NSResponder) -> RightSidebarMode? {
        if responder === outlineView { return .files }
        if responder === searchResultsView { return .find }
        if responder === searchField { return displayedSearchScope.activationMode }
        if let editor = searchField.currentEditor(), responder === editor {
            return displayedSearchScope.activationMode
        }
        var view = responder as? NSView
        while let candidate = view {
            if candidate === searchBarView {
                return displayedSearchScope.activationMode
            }
            if candidate === searchScrollView || candidate === searchResultsView {
                return .find
            }
            view = candidate.superview
        }
        return nil
    }

    private func refreshSearchIfNeeded() {
        guard displayedSearchScope == .contents else {
            if hasContentsQuery { preservedSearchNeedsRefresh = true }
            return
        }
        preservedSearchNeedsRefresh = false
        cancelPendingSearchRefresh()
#if DEBUG
        dlog(
            "file.search.request queryLen=\(queryState.contentsQuery.count) " +
            "rootReady=\(currentRootPath.isEmpty ? 0 : 1) local=\(currentProviderIsLocal ? 1 : 0) " +
            "revision=\(currentContentRevision) results=\(searchSnapshot.results.count) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width))"
        )
#endif
        searchController.search(request: FileSearchRequest(
            query: queryState.contentsQuery,
            rootPath: currentRootPath,
            isLocal: currentProviderIsLocal,
            contentRevision: currentContentRevision
        ))
    }

    private func refreshSearchAfterContentRevisionIfNeeded() {
        guard displayedSearchScope == .contents else {
            preservedSearchNeedsRefresh = hasContentsQuery
            pendingSearchRefreshAfterSettled = false
            return
        }
        guard searchSnapshot.isSearching else {
            pendingSearchRefreshAfterSettled = false
            refreshSearchIfNeeded()
            return
        }
        pendingSearchRefreshAfterSettled = true
#if DEBUG
        dlog(
            "file.search.contentRevision.defer queryLen=\(queryState.contentsQuery.count) " +
            "revision=\(currentContentRevision) results=\(searchSnapshot.results.count)"
        )
#endif
    }

    private func configureSearchDebounce() {
        searchDebounceCancellable = searchDebounceSubject
            .debounce(for: .milliseconds(searchDebounceDelayMilliseconds), scheduler: RunLoop.main)
            .sink { [weak self] debounceGeneration in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.displayedSearchScope == .contents,
                          self.searchDebounceGeneration == debounceGeneration else { return }
#if DEBUG
                    dlog(
                        "file.search.debounce.fire queryLen=\(self.queryState.contentsQuery.count) " +
                        "delayMs=\(self.searchDebounceDelayMilliseconds)"
                    )
#endif
                    self.refreshSearchIfNeeded()
                }
            }
    }

    private func scheduleSearchRefresh() {
        guard displayedSearchScope == .contents else { return }
        pendingSearchRefreshAfterSettled = false
        searchDebounceGeneration += 1
        let debounceGeneration = searchDebounceGeneration
#if DEBUG
        dlog(
            "file.search.debounce.schedule queryLen=\(queryState.contentsQuery.count) " +
            "delayMs=\(searchDebounceDelayMilliseconds)"
        )
#endif
        searchDebounceSubject.send(debounceGeneration)
    }

    private func cancelPendingSearchRefresh() {
        searchDebounceGeneration += 1
    }

    private func configureFileFilterDebounce() {
        fileFilterDebounceCancellable = fileFilterDebounceSubject
            .debounce(for: .milliseconds(searchDebounceDelayMilliseconds), scheduler: RunLoop.main)
            .sink { [weak self] debounceGeneration in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.displayedSearchScope == .names,
                          self.fileFilterDebounceGeneration == debounceGeneration else { return }
                    self.applyPendingFileFilter()
                }
            }
    }

    private func scheduleFileFilterRefresh() {
        guard displayedSearchScope == .names else { return }
        fileFilterDebounceGeneration += 1
        fileFilterDebounceSubject.send(fileFilterDebounceGeneration)
    }

    private func cancelPendingFileFilterRefresh() {
        fileFilterDebounceGeneration += 1
    }

    func applyPendingFileFilter() {
        cancelPendingFileFilterRefresh()
        guard displayedSearchScope == .names else { return }
        coordinator.setFileFilterQuery(queryState.namesQuery, in: outlineView)
        updateVisibility(
            hasContent: !currentRootPath.isEmpty,
            isLoading: currentIsLoading,
            statusMessage: currentStatusMessage
        )
    }

    private func pauseSearchPreservingState() {
        preservedSearchNeedsRefresh = preservedSearchNeedsRefresh || searchSnapshot.isSearching
        cancelPendingSearchRefresh()
        pendingSearchRefreshAfterSettled = false
        searchController.cancel(clear: false)
    }

    private func resumePreservedSearchIfNeeded() {
        guard displayedSearchScope == .contents, hasContentsQuery else { return }
        let normalizedQuery = queryState.contentsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if preservedSearchNeedsRefresh || searchSnapshot.query != normalizedQuery {
            refreshSearchIfNeeded()
        }
    }

    private func updateSearchLayout(hasContent: Bool? = nil, isLoading: Bool? = nil) {
        let effectiveHasContent = hasContent ?? !currentRootPath.isEmpty
        let effectiveIsLoading = isLoading ?? false
        let showSearchField = displayedSearchScope == .contents && effectiveHasContent && !effectiveIsLoading
        let showSearchResults = showSearchField
        let showTree = displayedSearchScope == .names && effectiveHasContent && !effectiveIsLoading
        let nextSearchBarHeight = showSearchField ? activeBarVisibleHeight : 0
        // Assigning isHidden/constraints unconditionally fires KVO even when unchanged,
        // which re-enters updateNSView and spins the main thread on macOS 26 (#4931).
        var changed = false
        if applyHidden(searchBarView, !showSearchField) { changed = true }
        if searchBarHeightConstraint.constant != nextSearchBarHeight {
            searchBarHeightConstraint.constant = nextSearchBarHeight
            changed = true
        }
        if applyHidden(searchScrollView, !showSearchResults) { changed = true }
        if applyHidden(scrollView, !showTree) { changed = true }
        if changed {
            needsLayout = true
        }
    }

    /// Sets `isHidden` only when it changes (a redundant write still fires KVO), returning whether it changed.
    @discardableResult
    private func applyHidden(_ view: NSView, _ hidden: Bool) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }
    private func applySearchSnapshot(_ snapshot: FileSearchSnapshot) {
        let snapshot = snapshot.groupingMatchesByFile()
#if DEBUG
        let debugApplyStart = ProcessInfo.processInfo.systemUptime
        let previousStatusName = debugSearchStatusName(searchSnapshot.status)
        let previousStatusTextLength = searchStatusLabel.stringValue.count
#endif
        let previousSelectedRow = searchResultsView.selectedRow
        let previousSelectedResults = searchResultsView.selectedRowIndexes.compactMap { searchSnapshot.results.indices.contains($0) ? searchSnapshot.results[$0] : nil }
        let previousResults = searchSnapshot.results
        searchSnapshot = snapshot
        searchStatusLabel.stringValue = statusText(for: snapshot)
        applySearchResultsUpdate(previousResults: previousResults, nextResults: snapshot.results)
#if DEBUG
        logSearchSnapshot(
            snapshot,
            startedAt: debugApplyStart,
            previousStatusName: previousStatusName,
            previousStatusTextLength: previousStatusTextLength
        )
#endif

        let shouldRunDeferredContentRefresh = !snapshot.isSearching && pendingSearchRefreshAfterSettled
        if shouldRunDeferredContentRefresh {
            pendingSearchRefreshAfterSettled = false
        }

        if !snapshot.results.isEmpty {
            let preservedRows = IndexSet(previousSelectedResults.compactMap { snapshot.results.firstIndex(of: $0) })
            let fallbackRow = previousSelectedRow >= 0 ? min(previousSelectedRow, snapshot.results.count - 1) : 0
            searchResultsView.selectRowIndexes(preservedRows.isEmpty ? IndexSet(integer: fallbackRow) : preservedRows, byExtendingSelection: false)
        }

        if shouldRunDeferredContentRefresh {
            refreshSearchIfNeeded()
        }
    }

    private func applySearchResultsUpdate(previousResults: [FileSearchResult], nextResults: [FileSearchResult]) {
        if previousResults == nextResults {
            return
        }

        if nextResults.count > previousResults.count &&
            nextResults.starts(with: previousResults) {
            let insertedRange = previousResults.count..<nextResults.count
            searchResultsView.insertRows(at: IndexSet(integersIn: insertedRange), withAnimation: [])
            return
        }

        if nextResults.count == previousResults.count {
            let changedRows = IndexSet(
                nextResults.indices.filter { nextResults[$0] != previousResults[$0] }
            )
            if !changedRows.isEmpty {
                searchResultsView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            }
            return
        }

        searchResultsView.reloadData()
    }

    private func statusText(for snapshot: FileSearchSnapshot) -> String {
        switch snapshot.status {
        case .idle:
            return ""
        case .unsupported:
            return String(localized: "fileExplorer.search.unsupported", defaultValue: "Local folders only")
        case .searching:
            return String(
                format: String(localized: "fileExplorer.search.searching", defaultValue: "%d matches, searching"),
                snapshot.results.count
            )
        case .noMatches:
            return String(localized: "fileExplorer.search.noMatches", defaultValue: "No matches")
        case .matches:
            return String(
                format: String(localized: "fileExplorer.search.matches", defaultValue: "%d matches"),
                snapshot.results.count
            )
        case .limited(let limit):
            return String(
                format: String(localized: "fileExplorer.search.limit", defaultValue: "First %d matches"),
                limit
            )
        case .failed(let message):
            return String(
                format: String(localized: "fileExplorer.search.failed", defaultValue: "Search failed: %@"),
                message
            )
        }
    }

#if DEBUG
    private func debugSearchNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func debugSearchNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func debugSearchStatusName(_ status: FileSearchSnapshot.Status) -> String {
        switch status {
        case .idle:
            return "idle"
        case .unsupported:
            return "unsupported"
        case .searching:
            return "searching"
        case .noMatches:
            return "noMatches"
        case .matches:
            return "matches"
        case .limited(let limit):
            return "limited(\(limit))"
        case .failed:
            return "failed"
        }
    }

    private func logSearchLayoutIfNeeded(startedAt: TimeInterval, reason: String) {
        guard displayedSearchScope == .contents else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fieldWidth = searchField.frame.width
        let statusWidth = searchStatusLabel.frame.width
        let firstLayout = debugLastSearchLayoutFieldWidth < 0 || debugLastSearchLayoutStatusWidth < 0
        let fieldDelta = debugLastSearchLayoutFieldWidth >= 0
            ? abs(fieldWidth - debugLastSearchLayoutFieldWidth)
            : 0
        let statusDelta = debugLastSearchLayoutStatusWidth >= 0
            ? abs(statusWidth - debugLastSearchLayoutStatusWidth)
            : 0
        let layoutMs = max(0, (now - startedAt) * 1000)
        let widthChanged = fieldDelta > 0.5 || statusDelta > 0.5
        let slowLayout = layoutMs >= 8
        guard firstLayout || widthChanged || slowLayout else { return }

        debugLastSearchLayoutFieldWidth = fieldWidth
        debugLastSearchLayoutStatusWidth = statusWidth
        let sinceKeyMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        dlog(
            "file.search.layout reason=\(reason) fieldW=\(debugSearchNumber(fieldWidth)) " +
            "statusW=\(debugSearchNumber(statusWidth)) fieldDelta=\(debugSearchNumber(fieldDelta)) " +
            "statusDelta=\(debugSearchNumber(statusDelta)) layoutMs=\(debugSearchNumber(layoutMs)) " +
            "sinceKeyMs=\(sinceKeyMs) queryLen=\(searchField.stringValue.count) " +
            "results=\(searchSnapshot.results.count) status=\(debugSearchStatusName(searchSnapshot.status))"
        )
    }

    private func logSearchSnapshot(
        _ snapshot: FileSearchSnapshot,
        startedAt: TimeInterval,
        previousStatusName: String,
        previousStatusTextLength: Int
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let applyMs = max(0, (now - startedAt) * 1000)
        let statusName = debugSearchStatusName(snapshot.status)
        let resultDelta = debugLastLoggedSearchResultCount >= 0
            ? abs(snapshot.results.count - debugLastLoggedSearchResultCount)
            : snapshot.results.count
        let shouldLog = statusName != debugLastLoggedSearchStatus ||
            resultDelta >= 50 ||
            applyMs >= 4
        guard shouldLog else { return }

        debugLastLoggedSearchStatus = statusName
        debugLastLoggedSearchResultCount = snapshot.results.count
        let sinceKeyMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        dlog(
            "file.search.snapshot status=\(statusName) previousStatus=\(previousStatusName) " +
            "results=\(snapshot.results.count) isSearching=\(snapshot.isSearching ? 1 : 0) " +
            "applyMs=\(debugSearchNumber(applyMs)) sinceKeyMs=\(sinceKeyMs) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width)) " +
            "statusIntrinsicW=\(debugSearchNumber(searchStatusLabel.intrinsicContentSize.width)) " +
            "statusTextLen=\(searchStatusLabel.stringValue.count) previousStatusTextLen=\(previousStatusTextLength)"
        )
    }
#endif

    private func closeSearchAndFocusOutline() {
        captureDisplayedQuery()
        switch displayedSearchScope {
        case .names:
            outlineView.endQuickSearch()
            _ = focusOutline()
        case .contents:
            guard hasContentsQuery else {
                _ = focusOutline()
                return
            }
            cancelPendingSearchRefresh()
            pendingSearchRefreshAfterSettled = false
            searchController.cancel(clear: true)
            queryState.setQuery("", for: .contents)
            searchBarView.apply(query: queryState.contentsQuery)
            applySearchSnapshot(.empty)
            updateVisibility(
                hasContent: !currentRootPath.isEmpty,
                isLoading: currentIsLoading,
                statusMessage: currentStatusMessage
            )
            _ = window?.makeFirstResponder(searchField)
        }
    }

}
