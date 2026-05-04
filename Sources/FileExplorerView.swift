import AppKit
import Bonsplit
import Combine
import SwiftUI

#if DEBUG
private func fileExplorerDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

// MARK: - File Explorer Panel (single NSViewRepresentable)

enum FileExplorerPanelPresentation: Equatable {
    case files
    case find

    var rightSidebarMode: RightSidebarMode {
        switch self {
        case .files: return .files
        case .find: return .find
        }
    }
}

/// The entire file explorer panel as one AppKit view hierarchy.
/// Contains the header bar (path + controls) and NSOutlineView, with no SwiftUI intermediaries.
struct FileExplorerPanelView: NSViewRepresentable {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    let onOpenFilePreview: (String) -> Void
    var presentation: FileExplorerPanelPresentation = .files

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, state: state, onOpenFilePreview: onOpenFilePreview)
    }

    func makeNSView(context: Context) -> FileExplorerContainerView {
        let container = FileExplorerContainerView(coordinator: context.coordinator, presentation: presentation)
        context.coordinator.containerView = container
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        context.coordinator.store = store
        context.coordinator.state = state
        context.coordinator.onOpenFilePreview = onOpenFilePreview
        container.updateHeader(store: store)
        container.updatePresentation(presentation)
        context.coordinator.reloadIfNeeded()
        container.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var store: FileExplorerStore
        var state: FileExplorerState
        var onOpenFilePreview: (String) -> Void
        weak var containerView: FileExplorerContainerView?
        weak var outlineView: NSOutlineView?
        private var lastRootNodeCount: Int = -1
        private var observationCancellable: AnyCancellable?
        private var styleObserver: Any?
        private var isUpdatingOutlineProgrammatically = false

        init(
            store: FileExplorerStore,
            state: FileExplorerState,
            onOpenFilePreview: @escaping (String) -> Void
        ) {
            self.store = store
            self.state = state
            self.onOpenFilePreview = onOpenFilePreview
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

        deinit {
            if let observer = styleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func observeStore() {
            observationCancellable = store.objectWillChange
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.reloadIfNeeded()
                }
        }

        func reloadIfNeeded() {
            guard let outlineView else { return }

            // Update empty state vs tree visibility
            containerView?.updateVisibility(hasContent: !store.rootPath.isEmpty, isLoading: store.isRootLoading)

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
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if expandedPaths.contains(node.path) && outlineView.isExpandable(node) {
                    outlineView.expandItem(node)
                }
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
                return store.rootNodes.count
            }
            guard let node = item as? FileExplorerNode else { return 0 }
            return node.sortedChildren?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return store.rootNodes[index]
            }
            guard let node = item as? FileExplorerNode,
                  let children = node.sortedChildren else {
                return FileExplorerNode(name: "", path: "", isDirectory: false)
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
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
            store.expand(node: node)
            return node.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            store.collapse(node: node)
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingOutlineProgrammatically,
                  let outlineView = notification.object as? NSOutlineView else {
                return
            }
            guard outlineView.selectedRow >= 0,
                  outlineView.selectedRow < outlineView.numberOfRows,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode else {
                store.select(node: nil)
                return
            }
            store.select(node: node)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            if !store.isExpanded(node) {
                store.expand(node: node)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
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

        func selectBestQuickSearchMatch(in outlineView: NSOutlineView, query: String) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty, outlineView.numberOfRows > 0 else { return }
            let lowerQuery = trimmedQuery.lowercased()
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.name.lowercased().contains(lowerQuery) {
                    selectRow(row, in: outlineView, scroll: true)
                    return
                }
            }
        }

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

        private func resolvedSelectionRow(in outlineView: NSOutlineView) -> Int? {
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

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0,
                  let node = sender.item(atRow: row) as? FileExplorerNode else { return }

            if node.isDirectory {
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else if sender.isExpandable(node) {
                    sender.expandItem(node)
                }
                return
            }

            guard store.provider is LocalFileExplorerProvider else { return }
            onOpenFilePreview(node.path)
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
                let openItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.openDefault", defaultValue: "Open in Default Editor"),
                    action: #selector(contextMenuOpenInDefaultEditor(_:)),
                    keyEquivalent: ""
                )
                openItem.target = self
                openItem.representedObject = node
                menu.addItem(openItem)
            }

            if isLocal {
                let revealItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder"),
                    action: #selector(contextMenuRevealInFinder(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = node
                menu.addItem(revealItem)

                menu.addItem(.separator())
            }

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

        @objc private func contextMenuOpenInDefaultEditor(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
        }

        @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
        }

        @objc private func contextMenuCopyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }

        @objc private func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            let rootPath = store.rootPath
            var relativePath = node.path
            if relativePath.hasPrefix(rootPath) {
                relativePath = String(relativePath.dropFirst(rootPath.count))
                if relativePath.hasPrefix("/") {
                    relativePath = String(relativePath.dropFirst())
                }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(relativePath, forType: .string)
        }
    }
}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and outline view.
final class FileExplorerContainerView: NSView {
    private let headerView: FileExplorerHeaderView
    private let searchBarView: NSView
    private let searchField: FileExplorerSearchField
    private let searchStatusLabel: NSTextField
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    private let searchScrollView: NSScrollView
    private let searchResultsView: FileExplorerSearchResultsTableView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private let searchController: FileSearchController
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private var searchSnapshot = FileSearchSnapshot.empty
    private var currentRootPath = ""
    private var currentProviderIsLocal = false
    private var currentContentRevision = 0
    private var isSearchVisible = false
    private var presentation: FileExplorerPanelPresentation
    private let coordinator: FileExplorerPanelView.Coordinator

    init(coordinator: FileExplorerPanelView.Coordinator, presentation: FileExplorerPanelPresentation) {
        headerView = FileExplorerHeaderView()
        searchBarView = NSView()
        searchField = FileExplorerSearchField()
        searchStatusLabel = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        searchScrollView = NSScrollView()
        searchResultsView = FileExplorerSearchResultsTableView()
        emptyLabel = NSTextField(labelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        searchController = FileSearchController()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Search bar
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.isHidden = true
        addSubview(searchBarView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("FileExplorerSearchField")
        searchField.placeholderString = String(localized: "fileExplorer.search.placeholder", defaultValue: "Search files")
        searchField.font = .systemFont(ofSize: 12, weight: .regular)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: true)
        }
        searchField.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchField.onFocus = { [weak self] in
            guard let self else { return }
            self.isSearchVisible = true
            if let window = self.window {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: self.representedRightSidebarMode(), in: window)
            }
            self.updateSearchLayout()
        }
        searchBarView.addSubview(searchField)

        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.lineBreakMode = .byTruncatingTail
        searchStatusLabel.maximumNumberOfLines = 1
        searchStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBarView.addSubview(searchStatusLabel)

        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
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

        // Outline view setup
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = FileExplorerStyle.current.indentation
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.onQuickSearchChanged = { [weak self] query in
            self?.headerView.updateQuickSearch(query: query)
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
        searchResultsView.rowHeight = 46
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
            guard let self, let window = self.window else { return }
            AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: self.representedRightSidebarMode(), in: window)
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

        searchController.onSnapshotChanged = { [weak self] snapshot in
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

            searchField.leadingAnchor.constraint(equalTo: searchBarView.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBarView.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            searchStatusLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            searchStatusLabel.trailingAnchor.constraint(equalTo: searchBarView.trailingAnchor, constant: -8),
            searchStatusLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            searchController.cancel(clear: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
#if DEBUG
        dlog(
            "file.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateHeader(store: FileExplorerStore) {
        let nextRootPath = store.rootPath
        let nextProviderIsLocal = store.provider is LocalFileExplorerProvider
        let nextContentRevision = store.contentRevision
        let shouldRefreshSearch = nextRootPath != currentRootPath ||
            nextProviderIsLocal != currentProviderIsLocal ||
            nextContentRevision != currentContentRevision

        currentRootPath = nextRootPath
        currentProviderIsLocal = nextProviderIsLocal
        currentContentRevision = nextContentRevision
        headerView.update(displayPath: store.displayRootPath)
        if shouldRefreshSearch {
            refreshSearchIfNeeded()
        }
    }

    func representedRightSidebarMode() -> RightSidebarMode {
        presentation.rightSidebarMode
    }

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else {
            if presentation == .find {
                isSearchVisible = true
                updateSearchLayout()
                refreshSearchIfNeeded()
            }
            return
        }

        presentation = nextPresentation
        switch presentation {
        case .files:
            isSearchVisible = false
            searchController.cancel(clear: false)
        case .find:
            isSearchVisible = true
            refreshSearchIfNeeded()
        }
        updateSearchLayout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateVisibility(hasContent: Bool, isLoading: Bool) {
        headerView.isHidden = !hasContent
        updateSearchLayout(hasContent: hasContent, isLoading: isLoading)
        let searchCanShow = isSearchVisible && hasContent && !isLoading
        emptyLabel.isHidden = hasContent || searchCanShow
        loadingIndicator.isHidden = !isLoading
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
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
        isSearchVisible = true
        updateSearchLayout()
        refreshSearchIfNeeded()
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
        if isSearchVisible {
            isSearchVisible = false
            searchController.cancel(clear: true)
            searchField.stringValue = ""
            searchSnapshot = .empty
            searchResultsView.reloadData()
            updateSearchLayout()
        }
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
        if responder === outlineView || responder === searchResultsView || responder === searchField {
            return true
        }
        if let editor = searchField.currentEditor(), responder === editor {
            return true
        }
        var view = responder as? NSView
        while let candidate = view {
            if candidate === searchBarView || candidate === searchScrollView || candidate === searchResultsView {
                return true
            }
            view = candidate.superview
        }
        return false
    }

    private func refreshSearchIfNeeded() {
        guard isSearchVisible else { return }
        searchController.search(
            query: searchField.stringValue,
            rootPath: currentRootPath,
            isLocal: currentProviderIsLocal,
            contentRevision: currentContentRevision
        )
    }

    private func updateSearchLayout(hasContent: Bool? = nil, isLoading: Bool? = nil) {
        let effectiveHasContent = hasContent ?? !currentRootPath.isEmpty
        let effectiveIsLoading = isLoading ?? false
        let showSearch = isSearchVisible && effectiveHasContent && !effectiveIsLoading
        searchBarView.isHidden = !showSearch
        searchBarHeightConstraint.constant = showSearch ? RightSidebarChromeMetrics.secondaryBarHeight : 0
        searchScrollView.isHidden = !showSearch
        scrollView.isHidden = showSearch || !effectiveHasContent || effectiveIsLoading
        needsLayout = true
    }

    private func applySearchSnapshot(_ snapshot: FileSearchSnapshot) {
        let previousSelectedRow = searchResultsView.selectedRow
        searchSnapshot = snapshot
        searchStatusLabel.stringValue = statusText(for: snapshot)
        searchResultsView.reloadData()

        guard !snapshot.results.isEmpty else { return }
        let selectedRow = previousSelectedRow >= 0
            ? min(previousSelectedRow, snapshot.results.count - 1)
            : 0
        searchResultsView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
    }

    private func statusText(for snapshot: FileSearchSnapshot) -> String {
        switch snapshot.status {
        case .idle:
            return String(localized: "fileExplorer.search.empty", defaultValue: "Type to search")
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

    private func closeSearchAndFocusOutline() {
        if presentation == .find {
            let hadQuery = !searchField.stringValue.isEmpty
            searchController.cancel(clear: true)
            searchField.stringValue = ""
            applySearchSnapshot(.empty)
            updateSearchLayout()
            if hadQuery {
                _ = focusSearchField()
                return
            }
            if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }

        isSearchVisible = false
        searchController.cancel(clear: true)
        searchField.stringValue = ""
        searchSnapshot = .empty
        searchResultsView.reloadData()
        updateSearchLayout()
        _ = focusOutline()
    }

    private func moveSearchSelection(by delta: Int, focusResults: Bool) {
        guard !searchSnapshot.results.isEmpty else { return }
        let currentRow = searchResultsView.selectedRow >= 0
            ? searchResultsView.selectedRow
            : (delta >= 0 ? -1 : searchSnapshot.results.count)
        let targetRow = min(max(currentRow + delta, 0), searchSnapshot.results.count - 1)
        searchResultsView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        searchResultsView.scrollRowToVisible(targetRow)
        if focusResults, let window {
            _ = window.makeFirstResponder(searchResultsView)
        }
    }

    private func searchResult(forMenuItem sender: NSMenuItem) -> FileSearchResult? {
        guard let row = (sender.representedObject as? NSNumber)?.intValue,
              row >= 0,
              row < searchSnapshot.results.count else {
            return nil
        }
        return searchSnapshot.results[row]
    }

    fileprivate func openSelectedSearchResult() {
        let row = searchResultsView.selectedRow
        guard row >= 0, row < searchSnapshot.results.count else { return }
        coordinator.onOpenFilePreview(searchSnapshot.results[row].path)
    }

    @objc private func openSelectedSearchResultFromTable(_ sender: NSTableView) {
        openSelectedSearchResult()
    }

    @objc private func contextMenuOpenSearchResultInCmux(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        coordinator.onOpenFilePreview(result.path)
    }

    @objc private func contextMenuOpenSearchResultInDefaultEditor(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        PreferredEditorSettings.open(URL(fileURLWithPath: result.path))
    }

    @objc private func contextMenuRevealSearchResultInFinder(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        NSWorkspace.shared.selectFile(result.path, inFileViewerRootedAtPath: "")
    }

    @objc private func contextMenuCopySearchResultPath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.path, forType: .string)
    }

    @objc private func contextMenuCopySearchResultRelativePath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.relativePath, forType: .string)
    }
}

extension FileExplorerContainerView: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField else { return }
        refreshSearchIfNeeded()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            openSelectedSearchResult()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearchAndFocusOutline()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSearchSelection(by: 1, focusResults: true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSearchSelection(by: -1, focusResults: true)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        searchSnapshot.results.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < searchSnapshot.results.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileSearchResultCell")
        let cellView: FileExplorerSearchResultCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerSearchResultCellView {
            cellView = existing
        } else {
            cellView = FileExplorerSearchResultCellView(identifier: identifier)
        }
        cellView.configure(with: searchSnapshot.results[row])
        return cellView
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === searchResultsView,
              row >= 0,
              row < searchSnapshot.results.count else {
            return nil
        }
        let result = searchSnapshot.results[row]
        return FilePreviewDragPasteboardWriter(
            filePath: result.path,
            displayTitle: (result.relativePath as NSString).lastPathComponent
        )
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard tableView === searchResultsView else { return }
        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: NSPasteboard(name: .drag))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let searchMenu = searchResultsView.menu, menu === searchMenu else { return }
        menu.removeAllItems()
        let clickedRow = searchResultsView.clickedRow
        let row = clickedRow >= 0 ? clickedRow : searchResultsView.selectedRow
        guard row >= 0, row < searchSnapshot.results.count else { return }
        if clickedRow >= 0 {
            searchResultsView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let openInCmuxItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in cmux"),
            action: #selector(contextMenuOpenSearchResultInCmux(_:)),
            keyEquivalent: ""
        )
        openInCmuxItem.target = self
        openInCmuxItem.representedObject = NSNumber(value: row)
        menu.addItem(openInCmuxItem)

        let openDefaultItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.openDefault", defaultValue: "Open in Default Editor"),
            action: #selector(contextMenuOpenSearchResultInDefaultEditor(_:)),
            keyEquivalent: ""
        )
        openDefaultItem.target = self
        openDefaultItem.representedObject = NSNumber(value: row)
        menu.addItem(openDefaultItem)

        let revealItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder"),
            action: #selector(contextMenuRevealSearchResultInFinder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.representedObject = NSNumber(value: row)
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let copyPathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
            action: #selector(contextMenuCopySearchResultPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = NSNumber(value: row)
        menu.addItem(copyPathItem)

        let copyRelativePathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
            action: #selector(contextMenuCopySearchResultRelativePath(_:)),
            keyEquivalent: ""
        )
        copyRelativePathItem.target = self
        copyRelativePathItem.representedObject = NSNumber(value: row)
        menu.addItem(copyRelativePathItem)
    }
}

private final class FileExplorerSearchField: NSSearchField {
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = searchFieldMoveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    private func searchFieldMoveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1
            case 35: return -1
            default: return nil
            }
        }
        guard flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.keyCode {
        case 125: return 1
        case 126: return -1
        default: return nil
        }
    }
}

private final class FileExplorerSearchResultsTableView: NSTableView {
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func redrawVisibleRows() {
        setNeedsDisplay(bounds)
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, numberOfRows)
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }
}

private final class FileExplorerSearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1

        addSubview(pathLabel)
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            previewLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with result: FileSearchResult) {
        pathLabel.stringValue = "\(result.relativePath):\(result.lineNumber)"
        previewLabel.stringValue = result.preview.isEmpty ? " " : result.preview
        toolTip = "\(result.path):\(result.lineNumber):\(result.columnNumber)"
    }
}

// MARK: - Header View (AppKit)

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
final class FileExplorerHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private var displayPath = ""
    private var quickSearchQuery: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        applyHeaderState()
    }

    func update(displayPath: String) {
        self.displayPath = displayPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let quickSearchQuery {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = "/" + quickSearchQuery
        } else {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = displayPath
        }
    }
}

// MARK: - Cell View

final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    private var nameLabelTrailingToLoadingConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToContainerConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(loadingIndicator)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        nameLabelTrailingToLoadingConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: loadingIndicator.leadingAnchor,
            constant: -2
        )
        nameLabelTrailingToContainerConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -2
        )
        NSLayoutConstraint.activate([
            nameLabelTrailingToLoadingConstraint,
            nameLabelTrailingToContainerConstraint
        ])
        nameLabelTrailingToLoadingConstraint.isActive = false
    }

    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        let style = FileExplorerStyle.current

        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont

        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            if node.isDirectory {
                let folderIcon = NSWorkspace.shared.icon(for: .folder)
                folderIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = folderIcon
                iconView.contentTintColor = nil
            } else {
                let fileIcon = NSWorkspace.shared.icon(forFileType: (node.name as NSString).pathExtension)
                fileIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = fileIcon
                iconView.contentTintColor = nil
            }
        } else {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: style.iconSize, weight: style.iconWeight)
            if node.isDirectory {
                iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = style.folderIconTint
            } else {
                iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = style.fileIconTint
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = true
            nameLabelTrailingToContainerConstraint.isActive = false
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToContainerConstraint.isActive = true
        }

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.toolTip = error
        } else if let gitStatus {
            nameLabel.textColor = style.gitColor(for: gitStatus)
            nameLabel.toolTip = node.path
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.toolTip = node.path
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

// MARK: - Non-Animating Outline View

/// NSOutlineView subclass that disables expand/collapse animations and adds leading margin.
final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    var onQuickSearchChanged: ((String?) -> Void)?
    private var quickSearchActive = false
    private var quickSearchQuery = ""

    override func keyDown(with event: NSEvent) {
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if quickSearchActive, handleQuickSearchKey(event) {
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return
        }

        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return
        }

        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            beginQuickSearch()
            return
        }

        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if quickSearchActive, handleQuickSearchKey(event) {
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            endQuickSearch()
            redrawVisibleRows()
        }
        return result
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: expandChildren)
        NSAnimationContext.endGrouping()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingMargin
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let cellShift: CGFloat = Self.leadingMargin - 6
        frame.origin.x += cellShift
        frame.size.width -= cellShift
        return frame
    }

    private func redrawVisibleRows() {
        setNeedsDisplay(bounds)
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, numberOfRows)
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private var fileExplorerCoordinator: FileExplorerPanelView.Coordinator? {
        dataSource as? FileExplorerPanelView.Coordinator
    }

    private func beginQuickSearch() {
        quickSearchActive = true
        quickSearchQuery = ""
        onQuickSearchChanged?(quickSearchQuery)
    }

    private func endQuickSearch() {
        guard quickSearchActive || !quickSearchQuery.isEmpty else { return }
        quickSearchActive = false
        quickSearchQuery = ""
        onQuickSearchChanged?(nil)
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 51 {
            if !quickSearchQuery.isEmpty {
                quickSearchQuery.removeLast()
                onQuickSearchChanged?(quickSearchQuery)
                fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
            }
            return true
        }
        guard RightSidebarKeyboardNavigation.isPlainPrintableText(event) else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return true
        }
        quickSearchQuery += text
        onQuickSearchChanged?(quickSearchQuery)
        fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
        return true
    }
}

// MARK: - Row View

final class FileExplorerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let style = FileExplorerStyle.current
        let focused = isKeyboardFocusActive
        let inset = style.selectionInset
        let insetRect = bounds.insetBy(dx: inset, dy: inset > 0 ? 1 : 0)
        let path = NSBezierPath(
            roundedRect: insetRect,
            xRadius: style.selectionRadius,
            yRadius: style.selectionRadius
        )

        selectionFillColor(isFocused: focused).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        guard let outlineView = enclosingOutlineView else { return false }
        return window?.isKeyWindow == true && window?.firstResponder === outlineView
    }

    private var enclosingOutlineView: NSOutlineView? {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return outlineView
            }
            view = candidate.superview
        }
        return nil
    }

    private func selectionFillColor(isFocused: Bool) -> NSColor {
        if isFocused {
            return .controlAccentColor.withAlphaComponent(0.20)
        }
        return .labelColor.withAlphaComponent(0.08)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isKeyboardFocusActive ? .emphasized : .normal
    }
}
