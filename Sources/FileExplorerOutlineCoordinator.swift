import AppKit
import CmuxFileTree
import SwiftUI

extension FileExplorerPanelView {
    /// Data source, delegate and tree observer for the Files outline.
    ///
    /// Rows are the store's ``FileExplorerNode`` objects, so child lookups are
    /// `O(1)` and a refresh that keeps a path keeps its row. Store diffs become
    /// `removeItems`/`insertItems` batches; nothing here calls `reloadData`
    /// except a full reset (new root or provider).
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
        FileExplorerTreeObserving {
        var store: FileExplorerStore {
            didSet {
                guard oldValue !== store else { return }
                oldValue.removeTreeObserver(self)
                store.addTreeObserver(self)
                rebuildOutline()
            }
        }
        var state: FileExplorerState
        var onOpenFilePreview: (String) -> Void
        var placement: FileExplorerPanelPlacement
        var onFocus: (() -> Void)?
        var onContainerChange: ((FileExplorerContainerView?) -> Void)?
        weak var containerView: FileExplorerContainerView?
        weak var outlineView: NSOutlineView? {
            didSet {
                guard oldValue !== outlineView else { return }
                rebuildOutline()
            }
        }
        let iconCache = FileExplorerIconCache()
        var isUpdatingOutlineProgrammatically = false
        private var styleObserver: Any?
        private var scrollEndObserver: Any?
        weak var renamingCell: FileExplorerCellView?
        var renamingPath: String?
        // Keep one coordinator-level record for the promoted native source.
        // The source view can be replaced during SwiftUI reconstruction, so
        // view-local markers alone cannot reclaim a lost endedAt callback.
        weak var activeNativeDragSourceView: NSView?
        weak var activeNativeDragWriter: FilePreviewDragPasteboardWriter?
        var activeNativeDragSession: NSDraggingSession?
        var activeNativeDragOwnerships: [FilePreviewNativeDragOwnership] = []
        lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
            self?.previewWriterDidDeallocate(tokenID: tokenID)
        }

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
            store.addTreeObserver(self)
            styleObserver = NotificationCenter.default.addObserver(
                forName: .fileExplorerStyleDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyStyleChange()
                }
            }
            scrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = notification.object as? NSScrollView,
                          scrollView === self.outlineView?.enclosingScrollView else { return }
                    self.store.scheduleViewStateSave()
                }
            }
        }

        deinit {
            if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
            if let scrollEndObserver { NotificationCenter.default.removeObserver(scrollEndObserver) }
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
                guard let window else { return }
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: mode, in: window)
            case .pane:
                onFocus?()
            }
        }

        /// Updates root-level chrome from SwiftUI. Rows never reload here.
        func reloadIfNeeded() {
            containerView?.updateVisibility(
                hasContent: !store.rootPath.isEmpty,
                isLoading: store.isRootLoading,
                statusMessage: store.rootStatusMessage,
                showsRemoteTarget: store.provider is any RemoteFileExplorerProvider
            )
        }

        // MARK: - Full rebuild

        /// Reloads rows from the store and re-applies expansion and selection.
        /// Runs only when the outline or store is replaced or the tree resets.
        func rebuildOutline() {
            guard let outlineView else { return }
            let style = FileExplorerStyle.current
            if outlineView.rowHeight != style.rowHeight { outlineView.rowHeight = style.rowHeight }
            withProgrammaticOutlineUpdate {
                outlineView.reloadData()
                expandStoredExpansion(in: store.rootNodes, outlineView: outlineView)
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
            }
        }

        private func expandStoredExpansion(in nodes: [FileExplorerNode], outlineView: NSOutlineView) {
            for node in nodes where node.isDirectory && store.expandedPaths.contains(node.path) {
                if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                if let children = node.children {
                    expandStoredExpansion(in: children, outlineView: outlineView)
                }
            }
        }

        private func applyStyleChange() {
            guard let outlineView else { return }
            let style = FileExplorerStyle.current
            outlineView.indentationPerLevel = style.indentation
            outlineView.rowHeight = style.rowHeight
            reconfigureVisibleRows()
        }

        /// Reconfigures the cells on screen, for style, font or appearance changes.
        func reconfigureVisibleRows() {
            guard let outlineView else { return }
            let range = outlineView.rows(in: outlineView.visibleRect)
            guard range.location != NSNotFound else { return }
            for row in range.location..<min(range.location + range.length, outlineView.numberOfRows) {
                reconfigureRow(row, in: outlineView)
            }
        }

        private func reconfigureRow(_ row: Int, in outlineView: NSOutlineView) {
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView,
                  !cell.isRenaming else { return }
            cell.configure(with: node, gitStatus: store.gitStatusByPath[node.path], iconCache: iconCache)
        }

        // MARK: - FileExplorerTreeObserving

        func fileExplorerTreeDidReset(_ store: FileExplorerStore) {
            cancelRenaming()
            guard let outlineView else { return }
            withProgrammaticOutlineUpdate { outlineView.reloadData() }
        }

        func fileExplorerTree(
            _ store: FileExplorerStore,
            didUpdateChildrenOf parent: FileExplorerNode?,
            diff: FileTreeChildrenDiff,
            updatedNodes: [FileExplorerNode]
        ) {
            guard let outlineView else { return }
            if let renamingPath, store.nodesByPath[renamingPath] == nil { cancelRenaming() }
            withProgrammaticOutlineUpdate {
                if let parent, outlineView.row(forItem: parent) < 0 || !outlineView.isItemExpanded(parent) {
                    // A hidden or collapsed folder: refresh its cached children
                    // and disclosure state; no rows move on screen.
                    if outlineView.row(forItem: parent) >= 0 {
                        outlineView.reloadItem(parent, reloadChildren: true)
                    }
                    return
                }
                if !diff.removed.isEmpty || !diff.inserted.isEmpty {
                    outlineView.beginUpdates()
                    if !diff.removed.isEmpty {
                        outlineView.removeItems(at: diff.removed, inParent: parent, withAnimation: [])
                    }
                    if !diff.inserted.isEmpty {
                        outlineView.insertItems(at: diff.inserted, inParent: parent, withAnimation: [])
                    }
                    outlineView.endUpdates()
                }
                for node in updatedNodes {
                    let row = outlineView.row(forItem: node)
                    if row >= 0 { reconfigureRow(row, in: outlineView) }
                }
                if !diff.removed.isEmpty, !store.selectedPaths.isEmpty {
                    applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
                }
            }
        }

        func fileExplorerTree(_ store: FileExplorerStore, didRefreshRowsFor nodes: [FileExplorerNode]) {
            guard let outlineView else { return }
            if nodes.count > 64 {
                reconfigureVisibleRows()
                return
            }
            for node in nodes {
                let row = outlineView.row(forItem: node)
                if row >= 0 { reconfigureRow(row, in: outlineView) }
            }
        }

        func fileExplorerTree(_ store: FileExplorerStore, expand nodes: [FileExplorerNode]) {
            guard let outlineView else { return }
            withProgrammaticOutlineUpdate {
                for node in nodes where outlineView.row(forItem: node) >= 0 && !outlineView.isItemExpanded(node) {
                    outlineView.expandItem(node)
                }
            }
        }

        func fileExplorerTreeDidChangeSelection(_ store: FileExplorerStore, scrollToAnchor: Bool) {
            guard let outlineView else { return }
            applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: scrollToAnchor)
        }

        func fileExplorerTree(_ store: FileExplorerStore, beginRenaming node: FileExplorerNode) {
            beginRenaming(node)
        }

        func fileExplorerTree(_ store: FileExplorerStore, restoreScrollTo node: FileExplorerNode, offset: Double) {
            guard let outlineView, let clipView = outlineView.enclosingScrollView?.contentView else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            let target = NSPoint(x: clipView.bounds.origin.x, y: outlineView.rect(ofRow: row).minY + offset)
            clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: target, size: clipView.bounds.size)).origin)
            outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        func fileExplorerTreeScrollAnchor(_ store: FileExplorerStore) -> (path: String, offset: Double)? {
            guard let outlineView, outlineView.numberOfRows > 0 else { return nil }
            let visible = outlineView.visibleRect
            let row = outlineView.row(at: NSPoint(x: visible.minX + 1, y: visible.minY + 1))
            guard row >= 0, let node = outlineView.item(atRow: row) as? FileExplorerNode else { return nil }
            return (node.path, Double(visible.minY - outlineView.rect(ofRow: row).minY))
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item else { return store.rootNodes.count }
            return (item as? FileExplorerNode)?.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item else { return store.rootNodes[index] }
            guard let node = item as? FileExplorerNode, let children = node.children, index < children.count else {
                return FileExplorerNode(name: "", path: "", isDirectory: false)
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileExplorerNode)?.isExpandable ?? false
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileExplorerNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
            let cellView = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerCellView
                ?? FileExplorerCellView(identifier: identifier)
            if cellView.isRenaming, renamingCell === cellView, renamingPath != node.path {
                cancelRenaming()
            }
            cellView.configure(with: node, gitStatus: store.gitStatusByPath[node.path], iconCache: iconCache)
            if store.provider is any RemoteFileExplorerProvider, node.isDirectory {
                cellView.onHover = { [weak self, weak node] isHovering in
                    guard let self, let node else { return }
                    if isHovering {
                        self.store.prefetchChildren(for: node)
                    } else {
                        self.store.cancelPrefetch(for: node)
                    }
                }
            } else {
                cellView.onHover = nil
            }
            return cellView
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode, node.isDirectory else { return false }
            store.expand(node: node)
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            let recursively = (outlineView as? FileExplorerNSOutlineView)?.isCollapsingChildren == true
            store.collapse(node: node, recursively: recursively)
            return true
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode,
                  let outlineView = notification.object as? NSOutlineView else { return }
            if !store.isExpanded(node) {
                store.expand(node: node)
            }
            // Children listed while this folder was collapsed are unknown to
            // AppKit's expansion memory; restore their expansion from the store.
            withProgrammaticOutlineUpdate {
                for child in node.children ?? [] where child.isDirectory && store.expandedPaths.contains(child.path) {
                    if !outlineView.isItemExpanded(child) { outlineView.expandItem(child) }
                }
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            if store.isExpanded(node) {
                store.collapse(node: node)
            }
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
            (outlineView as? FileExplorerNSOutlineView)?.selectionDidChangeForQuickLook()
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            FileExplorerRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileExplorerNode)?.name
        }

        // MARK: - Path-owned navigation

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

        /// Option-Right / Option-Left: expand or collapse the selection and
        /// everything below it, like Finder's list view.
        func performRecursiveDisclosure(expand: Bool, in outlineView: NSOutlineView) {
            let nodes = selectedNodes(in: outlineView).filter(\.isDirectory)
            for node in nodes {
                if expand {
                    store.expandRecursively(node: node)
                    withProgrammaticOutlineUpdate {
                        if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                    }
                } else {
                    store.collapse(node: node, recursively: true)
                    withProgrammaticOutlineUpdate {
                        outlineView.collapseItem(node, collapseChildren: true)
                    }
                }
            }
        }

        /// Selects the parent folder of the selection (Command-Up).
        func selectParentOfSelection(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode else { return }
            selectParent(of: node, in: outlineView)
        }

        /// Type-select: prefer names that start with `query` at or after the
        /// current row, then any prefix match, then a substring match.
        func selectBestQuickSearchMatch(in outlineView: NSOutlineView, query: String, startingAtCurrentRow: Bool = false) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty, outlineView.numberOfRows > 0 else { return }
            let rowCount = outlineView.numberOfRows
            let start = startingAtCurrentRow ? max(0, outlineView.selectedRow) : 0
            var substringMatch: Int?
            for offset in 0..<rowCount {
                let row = (start + offset) % rowCount
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                if node.name.range(of: trimmedQuery, options: options.union(.anchored)) != nil {
                    selectRow(row, in: outlineView, scroll: true)
                    return
                }
                if substringMatch == nil, node.name.range(of: trimmedQuery, options: options) != nil {
                    substringMatch = row
                }
            }
            if let substringMatch {
                selectRow(substringMatch, in: outlineView, scroll: true)
            }
        }

        /// Steps to the next (or previous) row whose name contains `query`.
        func selectNextQuickSearchMatch(in outlineView: NSOutlineView, query: String, forward: Bool) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let rowCount = outlineView.numberOfRows
            guard !trimmedQuery.isEmpty, rowCount > 0 else { return }
            let current = outlineView.selectedRow
            for step in 1...rowCount {
                let row = ((current + (forward ? step : -step)) % rowCount + rowCount) % rowCount
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    selectRow(row, in: outlineView, scroll: true)
                    return
                }
            }
        }

        @MainActor func openSelectedItem(in outlineView: NSOutlineView) { openNode(in: outlineView, at: outlineView.selectedRow) }

        func selectedNodes(in outlineView: NSOutlineView) -> [FileExplorerNode] {
            outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
        }

        private func expandSelectedItemOrMoveToChild(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode,
                  node.isDirectory else {
                return
            }

            selectRow(row, in: outlineView, scroll: true)

            if !store.isExpanded(node) || !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: true)
                return
            }

            guard let children = node.children, !children.isEmpty else {
                if node.children == nil { store.requestDescendIntoFirstChild(of: node) }
                return
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
            guard let child = node.children?.first else { return }
            let childRow = outlineView.row(forItem: child)
            guard childRow >= 0 else { return }
            selectRow(childRow, in: outlineView, scroll: true)
        }

        private func selectParent(of node: FileExplorerNode, in outlineView: NSOutlineView) {
            guard let parentNode = node.parent else { return }
            let parentRow = outlineView.row(forItem: parentNode)
            guard parentRow >= 0 else { return }
            selectRow(parentRow, in: outlineView, scroll: true)
        }

        /// Mirrors the store's path-owned selection into the outline. Rows are
        /// found by node identity, not by scanning; a selected path that is
        /// not on screen falls back to its nearest visible ancestor.
        func applyStoredSelection(
            in outlineView: NSOutlineView,
            fallbackToFirstVisible: Bool,
            scroll: Bool
        ) {
            var exactRows = IndexSet()
            for path in store.selectedPaths {
                if let node = store.nodesByPath[path] {
                    let row = outlineView.row(forItem: node)
                    if row >= 0 { exactRows.insert(row) }
                }
            }
            if !exactRows.isEmpty {
                withProgrammaticOutlineUpdate {
                    if outlineView.selectedRowIndexes != exactRows {
                        outlineView.selectRowIndexes(exactRows, byExtendingSelection: false)
                    }
                }
                if scroll {
                    let anchorRow = store.selectedPath
                        .flatMap { store.nodesByPath[$0] }
                        .map { outlineView.row(forItem: $0) }
                        .flatMap { $0 >= 0 ? $0 : nil }
                    if let row = anchorRow ?? exactRows.first { outlineView.scrollRowToVisible(row) }
                }
                return
            }
            if let selectedPath = store.selectedPath, let row = nearestVisibleAncestorRow(of: selectedPath, in: outlineView) {
                selectRow(row, in: outlineView, scroll: scroll, updateStore: false)
                return
            }
            guard fallbackToFirstVisible, outlineView.numberOfRows > 0 else { return }
            selectRow(0, in: outlineView, scroll: scroll)
        }

        private func nearestVisibleAncestorRow(of path: String, in outlineView: NSOutlineView) -> Int? {
            var cursor = (path as NSString).deletingLastPathComponent
            while !cursor.isEmpty, cursor != "/", FileExplorerStore.path(cursor, isContainedIn: store.rootPath),
                  cursor != store.rootPath {
                if let node = store.nodesByPath[cursor] {
                    let row = outlineView.row(forItem: node)
                    if row >= 0 { return row }
                }
                cursor = (cursor as NSString).deletingLastPathComponent
            }
            return nil
        }

        func resolvedSelectionRow(in outlineView: NSOutlineView) -> Int? {
            if let selectedPath = store.selectedPath, let node = store.nodesByPath[selectedPath] {
                let row = outlineView.row(forItem: node)
                if row >= 0 { return row }
            }
            if let selectedPath = store.selectedPath,
               let row = nearestVisibleAncestorRow(of: selectedPath, in: outlineView) {
                return row
            }
            guard outlineView.selectedRow >= 0,
                  outlineView.selectedRow < outlineView.numberOfRows,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode else {
                return nil
            }
            store.select(node: node)
            return outlineView.selectedRow
        }

        func selectRow(
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
            (outlineView as? FileExplorerNSOutlineView)?.selectionDidChangeForQuickLook()
        }

        func withProgrammaticOutlineUpdate(_ body: () -> Void) {
            let wasUpdating = isUpdatingOutlineProgrammatically
            isUpdatingOutlineProgrammatically = true
            defer { isUpdatingOutlineProgrammatically = wasUpdating }
            body()
        }

        @MainActor
        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            openNode(in: sender, at: row)
        }
    }
}
