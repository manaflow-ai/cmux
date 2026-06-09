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

private final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let applicationURL: URL?

    init(fileURL: URL, applicationURL: URL?) {
        self.fileURL = fileURL
        self.applicationURL = applicationURL
    }
}

private func addFileExplorerExternalOpenItems(
    to menu: NSMenu,
    fileURL: URL,
    target: AnyObject,
    action: Selector
) {
    let applications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
    let primaryApplication = applications.first { $0.isDefault } ?? applications.first
    let otherApplications = applications.filter { application in
        application.id != primaryApplication?.id
    }

    if let primaryApplication {
        let openItem = NSMenuItem(
            title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
            action: action,
            keyEquivalent: ""
        )
        openItem.target = target
        openItem.representedObject = FileExplorerExternalOpenRequest(
            fileURL: fileURL,
            applicationURL: primaryApplication.url
        )
        menu.addItem(openItem)

        guard !otherApplications.isEmpty else { return }
        let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
        for application in otherApplications {
            let appItem = NSMenuItem(
                title: application.displayName,
                action: action,
                keyEquivalent: ""
            )
            appItem.target = target
            appItem.representedObject = FileExplorerExternalOpenRequest(
                fileURL: fileURL,
                applicationURL: application.url
            )
            openWithMenu.addItem(appItem)
        }
        let openWithItem = NSMenuItem(title: FileExternalOpenText.openWithMenu, action: nil, keyEquivalent: "")
        openWithItem.submenu = openWithMenu
        menu.addItem(openWithItem)
    } else {
        let openItem = NSMenuItem(
            title: FileExternalOpenText.openExternally,
            action: action,
            keyEquivalent: ""
        )
        openItem.target = target
        openItem.representedObject = FileExplorerExternalOpenRequest(fileURL: fileURL, applicationURL: nil)
        menu.addItem(openItem)
    }
}

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

enum FileExplorerPanelPlacement: Equatable {
    case rightSidebar
    case pane
}

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

        /// A name edit waiting for its target row to appear after a reload.
        private struct PendingInlineEdit {
            let path: String
            /// True for a freshly created item (cancel removes it; commit may rename it).
            let isNewItem: Bool
            /// True when the edited item is a directory (selects the whole name vs. just the stem).
            let isDirectory: Bool
        }
        private var pendingInlineEdit: PendingInlineEdit?
        // The "edit in progress" flag lives on the store (`store.isInteractivelyEditing`) so the
        // watcher and this reload pass share one owner; the coordinator no longer keeps its own.

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

            // While the user is typing into an inline name field, do nothing: not even the
            // visibility/layout pass below, because a relayout lets the keyboard-focus
            // coordinator re-assert first responder onto the outline view and tear down the
            // active field editor (this is what made create-then-rename lose focus after ~1s).
            guard !store.isInteractivelyEditing else { return }

            // Update empty state vs tree visibility
            containerView?.updateVisibility(
                hasContent: !store.rootPath.isEmpty,
                isLoading: store.isRootLoading,
                statusMessage: store.rootStatusMessage
            )

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

            beginPendingInlineEditIfPossible(in: outlineView)
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

        // MARK: - File Actions (toolbar + context menu)

        /// Reloads the tree and re-fetches git status (Refresh toolbar button).
        func refreshTree() {
            store.reload()
            store.refreshGitStatus()
        }

        /// Collapses every folder to the root level (Collapse Folders toolbar button).
        func collapseAll() {
            guard let outlineView else { return }
            store.collapseAll()
            withProgrammaticOutlineUpdate {
                outlineView.collapseItem(nil, collapseChildren: true)
            }
        }

        /// Creates a uniquely-named file or folder in `directory` (or the toolbar's default
        /// target when nil), then begins inline editing so the user can name it.
        func beginCreate(isDirectory: Bool, inDirectory directory: String?) {
            guard store.canMutate else { return }
            guard let target = directory ?? store.targetDirectoryForNewItem() else { return }
            if target != store.rootPath {
                store.ensureExpanded(path: target)
            }
            let base = isDirectory
                ? String(localized: "fileExplorer.newFolder.defaultName", defaultValue: "untitled folder")
                : String(localized: "fileExplorer.newFile.defaultName", defaultValue: "untitled")
            let name = store.uniqueName(base: base, fileExtension: "", in: target)
            let result = isDirectory
                ? store.createDirectory(named: name, in: target)
                : store.createFile(named: name, in: target)
            switch result {
            case .success(let newPath):
                // Record the pending edit; the reload below brings the new row in, and
                // beginInlineEdit enters editing mode (gating reloads) once the row appears.
                pendingInlineEdit = PendingInlineEdit(path: newPath, isNewItem: true, isDirectory: isDirectory)
                store.setSelection(path: newPath)
                store.reload()
            case .failure(let error):
                presentMutationError(error)
            }
        }

        /// Begins inline editing of an existing item's name (context-menu Rename).
        func beginRename(node: FileExplorerNode) {
            guard let outlineView, store.canMutate else { return }
            beginInlineEdit(
                context: PendingInlineEdit(path: node.path, isNewItem: false, isDirectory: node.isDirectory),
                in: outlineView
            )
        }

        /// Duplicates `node` next to itself and selects the copy.
        func duplicateNode(_ node: FileExplorerNode) {
            switch store.duplicate(path: node.path) {
            case .success(let newPath):
                store.setSelection(path: newPath)
                store.reload()
            case .failure(let error):
                presentMutationError(error)
            }
        }

        /// Confirms, then moves `paths` to the Trash.
        func confirmAndDelete(paths: [String]) {
            guard store.canMutate, !paths.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            if paths.count == 1 {
                let name = (paths[0] as NSString).lastPathComponent
                let format = String(localized: "fileExplorer.delete.confirmSingle", defaultValue: "Are you sure you want to move \"%@\" to the Trash?")
                alert.messageText = String(format: format, name)
            } else {
                let format = String(localized: "fileExplorer.delete.confirmMultiple", defaultValue: "Are you sure you want to move these %lld items to the Trash?")
                alert.messageText = String(format: format, paths.count)
            }
            alert.informativeText = paths.count == 1
                ? String(localized: "fileExplorer.delete.confirmInfo.single", defaultValue: "You can restore it from the Trash.")
                : String(localized: "fileExplorer.delete.confirmInfo.multiple", defaultValue: "You can restore them from the Trash.")
            alert.addButton(withTitle: String(localized: "fileExplorer.delete.confirmButton", defaultValue: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "fileExplorer.dialog.cancel", defaultValue: "Cancel"))

            let perform: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                if case .failure(let error) = self.store.moveToTrash(paths: paths) {
                    self.presentMutationError(error)
                }
                self.store.reload()
            }
            if let window = outlineView?.window {
                alert.beginSheetModal(for: window, completionHandler: perform)
            } else {
                perform(alert.runModal())
            }
        }

        // MARK: - Inline Editing Plumbing

        /// First visible row whose node matches `path`, or nil if it isn't rendered yet.
        private func row(forPath path: String, in outlineView: NSOutlineView) -> Int? {
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileExplorerNode, node.path == path {
                    return row
                }
            }
            return nil
        }

        /// Applies a pending edit once its row exists; otherwise leaves it pending for the
        /// next reload (e.g. while a target subfolder is still loading its children).
        private func beginPendingInlineEditIfPossible(in outlineView: NSOutlineView) {
            guard let pending = pendingInlineEdit else { return }
            // Drop the pending edit if the item vanished from disk before we could focus it.
            // (Editing mode hasn't been entered yet here, so there's nothing to unwind.)
            if pending.isNewItem, !FileManager.default.fileExists(atPath: pending.path) {
                pendingInlineEdit = nil
                return
            }
            guard row(forPath: pending.path, in: outlineView) != nil else { return }
            pendingInlineEdit = nil
            beginInlineEdit(context: pending, in: outlineView)
        }

        private func beginInlineEdit(context: PendingInlineEdit, in outlineView: NSOutlineView) {
            guard let row = row(forPath: context.path, in: outlineView) else { return }
            store.isInteractivelyEditing = true
            withProgrammaticOutlineUpdate {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileExplorerCellView else {
                store.isInteractivelyEditing = false
                return
            }
            cell.onCommitEdit = { [weak self] newName in
                self?.finishInlineEdit(commit: true, newName: newName, context: context)
            }
            cell.onCancelEdit = { [weak self] in
                self?.finishInlineEdit(commit: false, newName: nil, context: context)
            }
            cell.beginEditing(selectingExtension: context.isDirectory)
        }

        private func finishInlineEdit(commit: Bool, newName: String?, context: PendingInlineEdit) {
            let trimmed = (newName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let currentName = (context.path as NSString).lastPathComponent

            // Exit editing mode (which re-enables watch reloads) and resync the tree once the
            // mutation below has run; reload() reflects the rename/discard.
            defer {
                store.isInteractivelyEditing = false
                store.reload()
            }

            // Cancel, or an empty/unchanged name: discard a brand-new item, keep an existing one.
            if !commit || trimmed.isEmpty || trimmed == currentName {
                if context.isNewItem, (!commit || trimmed.isEmpty) {
                    _ = store.discardJustCreated(path: context.path)
                }
                return
            }

            switch store.rename(path: context.path, to: trimmed) {
            case .success(let newPath):
                store.setSelection(path: newPath)
            case .failure(let error):
                // Keep a just-created item under its default name rather than orphaning it.
                presentMutationError(error)
            }
        }

        private func presentMutationError(_ error: FileExplorerMutationError) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "fileExplorer.mutation.errorTitle", defaultValue: "Couldn't complete the action")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "fileExplorer.dialog.ok", defaultValue: "OK"))
            if let window = outlineView?.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
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
            let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            guard !nodes.isEmpty else { store.select(node: nil); return }
            let anchor = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode : nil
            store.select(nodes: nodes, anchor: anchor ?? nodes.first)
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
            // Build path -> row once (O(V)) so multi-selection resolves in O(V + S) rather than
            // calling selectionResolution per selected path (which rescanned all rows each time).
            var rowForPath: [String: Int] = [:]
            rowForPath.reserveCapacity(outlineView.numberOfRows)
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileExplorerNode {
                    rowForPath[node.path] = row
                }
            }
            let exactRows = store.selectedPaths.reduce(into: IndexSet()) { if let row = rowForPath[$1] { $0.insert(row) } }
            if !exactRows.isEmpty {
                withProgrammaticOutlineUpdate { outlineView.selectRowIndexes(exactRows, byExtendingSelection: false) }
                let anchorRow = store.selectedPath.flatMap { rowForPath[$0] }
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

            if isLocal {
                let newFileItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.newFile", defaultValue: "New File"),
                    action: #selector(contextMenuNewFile(_:)),
                    keyEquivalent: ""
                )
                newFileItem.target = self
                newFileItem.representedObject = node
                menu.addItem(newFileItem)

                let newFolderItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.newFolder", defaultValue: "New Folder"),
                    action: #selector(contextMenuNewFolder(_:)),
                    keyEquivalent: ""
                )
                newFolderItem.target = self
                newFolderItem.representedObject = node
                menu.addItem(newFolderItem)

                menu.addItem(.separator())
            }

            if !node.isDirectory && isLocal {
                addFileExplorerExternalOpenItems(
                    to: menu,
                    fileURL: URL(fileURLWithPath: node.path),
                    target: self,
                    action: #selector(contextMenuOpenExternally(_:))
                )
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

            if isLocal {
                menu.addItem(.separator())

                let renameItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.rename", defaultValue: "Rename…"),
                    action: #selector(contextMenuRename(_:)),
                    keyEquivalent: ""
                )
                renameItem.target = self
                renameItem.representedObject = node
                menu.addItem(renameItem)

                let duplicateItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.duplicate", defaultValue: "Duplicate"),
                    action: #selector(contextMenuDuplicate(_:)),
                    keyEquivalent: ""
                )
                duplicateItem.target = self
                duplicateItem.representedObject = node
                menu.addItem(duplicateItem)

                let deleteItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.delete", defaultValue: "Move to Trash"),
                    action: #selector(contextMenuDelete(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = node
                menu.addItem(deleteItem)
            }
        }

        @objc private func contextMenuNewFile(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            beginCreate(isDirectory: false, inDirectory: directoryForCreation(relativeTo: node))
        }

        @objc private func contextMenuNewFolder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            beginCreate(isDirectory: true, inDirectory: directoryForCreation(relativeTo: node))
        }

        @objc private func contextMenuRename(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            beginRename(node: node)
        }

        @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            duplicateNode(node)
        }

        @objc private func contextMenuDelete(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            // Delete every selected item when the clicked row is part of the selection,
            // otherwise just the clicked item.
            let selected = store.selectedPaths
            let paths = selected.contains(node.path) ? Array(selected) : [node.path]
            confirmAndDelete(paths: paths)
        }

        /// New File/New Folder from a context click target a directory: the clicked folder,
        /// or the parent of a clicked file.
        private func directoryForCreation(relativeTo node: FileExplorerNode) -> String {
            node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
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
    private let searchBarView: NSView
    private let searchField: FileExplorerSearchField
    private let searchStatusLabel: NSTextField
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    private let searchScrollView: NSScrollView
    let searchResultsView: FileExplorerSearchResultsTableView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private let searchController: any FileSearchControlling
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private(set) var searchSnapshot = FileSearchSnapshot.empty
    private var currentRootPath = ""
    private var currentProviderIsLocal = false
    private var currentContentRevision = 0
    private let searchDebounceSubject = PassthroughSubject<Int, Never>()
    private var searchDebounceCancellable: AnyCancellable?
    private var searchDebounceGeneration = 0
    private var pendingSearchRefreshAfterSettled = false
    private var isSearchVisible = false {
        didSet {
            if !isSearchVisible {
                cancelPendingSearchRefresh()
                pendingSearchRefreshAfterSettled = false
            }
        }
    }
    private var presentation: FileExplorerPanelPresentation
    private let coordinator: FileExplorerPanelView.Coordinator
    private let searchDebounceDelayMilliseconds = 200
    private let searchBarVisibleHeight: CGFloat = 48

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
        searchBarView = NSView()
        searchField = FileExplorerSearchField()
        searchStatusLabel = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        searchScrollView = NSScrollView()
        searchResultsView = FileExplorerSearchResultsTableView()
        emptyLabel = NSTextField(labelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.searchController = searchController ?? FileSearchController()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)
        configureSearchDebounce()

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onNewFile = { [weak coordinator] in coordinator?.beginCreate(isDirectory: false, inDirectory: nil) }
        headerView.onNewFolder = { [weak coordinator] in coordinator?.beginCreate(isDirectory: true, inDirectory: nil) }
        headerView.onRefresh = { [weak coordinator] in coordinator?.refreshTree() }
        headerView.onCollapseAll = { [weak coordinator] in coordinator?.collapseAll() }
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
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.lineBreakMode = .byClipping
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
            self.updateSearchLayout()
        }
        searchBarView.addSubview(searchField)

        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.lineBreakMode = .byTruncatingTail
        searchStatusLabel.maximumNumberOfLines = 1
        searchStatusLabel.alignment = .left
        searchStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        outlineView.allowsMultipleSelection = true
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
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
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

            searchField.leadingAnchor.constraint(equalTo: searchBarView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchBarView.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: searchBarView.topAnchor, constant: 4),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            searchStatusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 4),
            searchStatusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            searchStatusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 2),

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
            cancelPendingSearchRefresh()
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
        let nextRootPath = store.rootPath
        let nextProviderIsLocal = store.provider is LocalFileExplorerProvider
        let nextContentRevision = store.contentRevision
        let searchScopeChanged = nextRootPath != currentRootPath ||
            nextProviderIsLocal != currentProviderIsLocal
        let contentRevisionChanged = nextContentRevision != currentContentRevision

        currentRootPath = nextRootPath
        currentProviderIsLocal = nextProviderIsLocal
        currentContentRevision = nextContentRevision
        headerView.update(displayPath: store.displayRootPath)
        headerView.setMutationActionsEnabled(store.canMutate)
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

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else {
            if presentation == .find {
                isSearchVisible = true
                updateSearchLayout()
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

    func updateVisibility(hasContent: Bool, isLoading: Bool, statusMessage: String?) {
        let normalizedStatus = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStatus = normalizedStatus?.isEmpty == false
        let canShowTree = hasContent && !hasStatus
        headerView.isHidden = !hasContent && !hasStatus
        updateSearchLayout(hasContent: canShowTree, isLoading: isLoading)
        let searchCanShow = isSearchVisible && canShowTree && !isLoading
        emptyLabel.stringValue = hasStatus
            ? normalizedStatus!
            : String(localized: "fileExplorer.empty", defaultValue: "No folder open")
        emptyLabel.isHidden = canShowTree || searchCanShow || isLoading
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
        cancelPendingSearchRefresh()
#if DEBUG
        dlog(
            "file.search.request queryLen=\(searchField.stringValue.count) " +
            "rootReady=\(currentRootPath.isEmpty ? 0 : 1) local=\(currentProviderIsLocal ? 1 : 0) " +
            "revision=\(currentContentRevision) results=\(searchSnapshot.results.count) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width))"
        )
#endif
        searchController.search(
            query: searchField.stringValue,
            rootPath: currentRootPath,
            isLocal: currentProviderIsLocal,
            contentRevision: currentContentRevision
        )
    }

    private func refreshSearchAfterContentRevisionIfNeeded() {
        guard isSearchVisible else {
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
            "file.search.contentRevision.defer queryLen=\(searchField.stringValue.count) " +
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
                          self.isSearchVisible,
                          self.searchDebounceGeneration == debounceGeneration else { return }
#if DEBUG
                    dlog(
                        "file.search.debounce.fire queryLen=\(self.searchField.stringValue.count) " +
                        "delayMs=\(self.searchDebounceDelayMilliseconds)"
                    )
#endif
                    self.refreshSearchIfNeeded()
                }
            }
    }

    private func scheduleSearchRefresh() {
        guard isSearchVisible else { return }
        pendingSearchRefreshAfterSettled = false
        searchDebounceGeneration += 1
        let debounceGeneration = searchDebounceGeneration
#if DEBUG
        dlog(
            "file.search.debounce.schedule queryLen=\(searchField.stringValue.count) " +
            "delayMs=\(searchDebounceDelayMilliseconds)"
        )
#endif
        searchDebounceSubject.send(debounceGeneration)
    }

    private func cancelPendingSearchRefresh() {
        searchDebounceGeneration += 1
    }

    private func updateSearchLayout(hasContent: Bool? = nil, isLoading: Bool? = nil) {
        let effectiveHasContent = hasContent ?? !currentRootPath.isEmpty
        let effectiveIsLoading = isLoading ?? false
        let showSearch = isSearchVisible && effectiveHasContent && !effectiveIsLoading
        searchBarView.isHidden = !showSearch
        searchBarHeightConstraint.constant = showSearch ? searchBarVisibleHeight : 0
        searchScrollView.isHidden = !showSearch
        scrollView.isHidden = showSearch || !effectiveHasContent || effectiveIsLoading
        needsLayout = true
    }

    private func applySearchSnapshot(_ snapshot: FileSearchSnapshot) {
#if DEBUG
        let debugApplyStart = ProcessInfo.processInfo.systemUptime
        let previousStatusName = debugSearchStatusName(searchSnapshot.status)
        let previousStatusTextLength = searchStatusLabel.stringValue.count
#endif
        let previousSelectedRow = searchResultsView.selectedRow
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
            let selectedRow = previousSelectedRow >= 0
                ? min(previousSelectedRow, snapshot.results.count - 1)
                : 0
            searchResultsView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
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
        guard isSearchVisible else { return }
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
        if presentation == .find {
            let hadQuery = !searchField.stringValue.isEmpty
            cancelPendingSearchRefresh()
            pendingSearchRefreshAfterSettled = false
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
        pendingSearchRefreshAfterSettled = false
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

    @objc private func contextMenuOpenSearchResultExternally(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
        FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }

    @objc private func contextMenuRevealSearchResultInFinder(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        FileExternalOpenAction.revealInFinder(fileURL: URL(fileURLWithPath: result.path))
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
            "file.search.input.changed queryLen=\(searchField.stringValue.count) gapMs=\(gapMs) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width)) " +
            "statusIntrinsicW=\(debugSearchNumber(searchStatusLabel.intrinsicContentSize.width)) " +
            "results=\(searchSnapshot.results.count) status=\(debugSearchStatusName(searchSnapshot.status)) " +
            "fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        scheduleSearchRefresh()
    }

    private func scrollSearchFieldEditorToInsertionPoint() {
        guard let editor = searchField.currentEditor() else { return }
        let selection = editor.selectedRange
        let textLength = (editor.string as NSString).length
        let cursorLocation = min(selection.location + selection.length, textLength)
        editor.scrollRangeToVisible(NSRange(location: cursorLocation, length: 0))
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
        if clickedRow >= 0 && !searchResultsView.selectedRowIndexes.contains(clickedRow) {
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

        addFileExplorerExternalOpenItems(
            to: menu,
            fileURL: URL(fileURLWithPath: searchSnapshot.results[row].path),
            target: self,
            action: #selector(contextMenuOpenSearchResultExternally(_:))
        )

        let revealItem = NSMenuItem(
            title: FileExternalOpenText.revealInFinder,
            action: #selector(contextMenuRevealSearchResultInFinder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.representedObject = NSNumber(value: row)
        menu.addItem(revealItem)

        menu.addItem(.separator())

        menu.addFileExplorerInsertPathItems(target: self, representedObject: NSNumber(value: row), insertAction: #selector(contextMenuInsertSearchResultPath(_:)), insertRelativeAction: #selector(contextMenuInsertSearchResultRelativePath(_:)))

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

final class FileExplorerSearchResultsTableView: NSTableView {
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?
    var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)?

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
            if onModeShortcut?(mode, window) == true {
                return
            }
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

    private let actionStack = NSStackView()
    private var newFileButton: NSButton!
    private var newFolderButton: NSButton!
    private var refreshButton: NSButton!
    private var collapseAllButton: NSButton!

    /// Invoked by the toolbar buttons. Wired by ``FileExplorerContainerView``.
    var onNewFile: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCollapseAll: (() -> Void)?

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

        newFileButton = makeToolbarButton(
            symbol: "doc.badge.plus",
            tooltip: String(localized: "fileExplorer.toolbar.newFile", defaultValue: "New File"),
            action: #selector(handleNewFile)
        )
        newFolderButton = makeToolbarButton(
            symbol: "folder.badge.plus",
            tooltip: String(localized: "fileExplorer.toolbar.newFolder", defaultValue: "New Folder"),
            action: #selector(handleNewFolder)
        )
        refreshButton = makeToolbarButton(
            symbol: "arrow.clockwise",
            tooltip: String(localized: "fileExplorer.toolbar.refresh", defaultValue: "Refresh Explorer"),
            action: #selector(handleRefresh)
        )
        collapseAllButton = makeToolbarButton(
            symbol: "arrow.down.right.and.arrow.up.left",
            tooltip: String(localized: "fileExplorer.toolbar.collapseAll", defaultValue: "Collapse Folders"),
            action: #selector(handleCollapseAll)
        )

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 2
        actionStack.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        [newFileButton, newFolderButton, refreshButton, collapseAllButton].forEach { actionStack.addArrangedSubview($0) }

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyHeaderState()
    }

    private func makeToolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier("FileExplorerToolbar.\(symbol)")
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    /// Enables the create buttons only when the provider supports mutation. Refresh and
    /// Collapse remain available for any root (including read-only SSH).
    func setMutationActionsEnabled(_ enabled: Bool) {
        newFileButton.isEnabled = enabled
        newFolderButton.isEnabled = enabled
    }

    @objc private func handleNewFile() { onNewFile?() }
    @objc private func handleNewFolder() { onNewFolder?() }
    @objc private func handleRefresh() { onRefresh?() }
    @objc private func handleCollapseAll() { onCollapseAll?() }

    func update(displayPath: String) {
        self.displayPath = displayPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let quickSearchQuery {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
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
            if fileExplorerCoordinator?.handleModeShortcut(mode, in: window) == true {
                return
            }
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
