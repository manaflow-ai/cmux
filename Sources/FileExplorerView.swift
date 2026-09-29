import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
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
    @Environment(\.colorScheme) private var colorScheme

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
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.containerView = container
        context.coordinator.onContainerChange?(container)
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
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
        // A native source is still allowed to own the container through its
        // matching `endedAt` callback. When no session was promoted, however,
        // clear any stale delegate marker so a dismantled search table does not
        // retain an obsolete native-session identity.
        nsView.clearNativeDragMarkersIfIdle()
        coordinator.onContainerChange?(nil)
    }

    // MARK: - Coordinator

    @MainActor
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
        private var lastContentRevision: Int = -1
        private var observationCancellable: AnyCancellable?
        private var styleObserver: Any?
        private var isUpdatingOutlineProgrammatically = false
        private var needsReloadAfterContextMenu = false
        // Keep one coordinator-level record for the promoted native source.
        // The source view can be replaced during SwiftUI reconstruction, so
        // view-local markers alone cannot reclaim a lost endedAt callback.
        private weak var activeNativeDragSourceView: NSView?
        private weak var activeNativeDragWriter: FilePreviewDragPasteboardWriter?
        private var activeNativeDragSession: NSDraggingSession?
        private var activeNativeDragOwnerships: [FilePreviewNativeDragOwnership] = []
        private lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
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
            observeStore()
            styleObserver = NotificationCenter.default.addObserver(
                forName: .fileExplorerStyleDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
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

            // Update empty state vs tree visibility
            containerView?.updateVisibility(
                hasContent: !store.rootPath.isEmpty,
                isLoading: store.isRootLoading,
                statusMessage: store.rootStatusMessage,
                showsRemoteTarget: store.provider is any RemoteFileExplorerProvider
            )

            // Reloading rows under an open context menu crashes AppKit's
            // highlight drawing (#12914). Catch up once the menu closes.
            if (outlineView as? FileExplorerNSOutlineView)?.isContextMenuOpen == true {
                needsReloadAfterContextMenu = true
                return
            }
            needsReloadAfterContextMenu = false

            let newCount = store.rootNodes.count
            let newContentRevision = store.contentRevision
            withProgrammaticOutlineUpdate {
                if newCount != lastRootNodeCount || newContentRevision != lastContentRevision {
                    lastRootNodeCount = newCount
                    lastContentRevision = newContentRevision
                    let expandedPaths = store.expandedPaths
                    outlineView.reloadData()
                    restoreExpansionState(expandedPaths, in: outlineView)
                } else {
                    refreshLoadedNodes(in: outlineView)
                }
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
            }
        }

        @MainActor
        func contextMenuDidClose() {
            guard needsReloadAfterContextMenu else { return }
            // Let AppKit finish tearing down the menu highlight first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsReloadAfterContextMenu else { return }
                self.reloadIfNeeded()
            }
        }

        private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
            // Expanding a row can reveal descendants, so re-read the row count each iteration.
            var row = 0
            while row < outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileExplorerNode,
                   expandedPaths.contains(node.path),
                   outlineView.isExpandable(node) {
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

        /// Applies the shared native-generation fence used by both file
        /// preview drag sources. A distinct `willBeginAt` session is an
        /// authoritative boundary and replaces the prior owner.
        func supersedeNativeDragIfNeeded(
            previousSession: NSDraggingSession?,
            newSession: NSDraggingSession,
            finishPrevious: () -> Void,
            clearPrevious: () -> Void
        ) {
            guard let previousSession, previousSession !== newSession else { return }
            // A distinct `willBeginAt` callback is itself an AppKit native
            // boundary. Sequence numbers are useful for terminal fencing but
            // cannot reject this promotion because the OS may reuse them.
            finishPrevious()
            clearPrevious()
        }

        func trackNativeDrag(
            sourceView: NSView,
            session: NSDraggingSession,
            writer: FilePreviewDragPasteboardWriter?,
            ownerships: [FilePreviewNativeDragOwnership]
        ) {
            activeNativeDragSourceView = sourceView
            activeNativeDragWriter = writer
            activeNativeDragSession = session
            activeNativeDragOwnerships = ownerships
        }

        private func clearTrackedSourceState() {
            if let outlineView = activeNativeDragSourceView as? FileExplorerNSOutlineView {
                outlineView.activeNativeDragDelegateMarker = nil
                outlineView.activeNativeDragWriter?.releaseSourceGraph()
                outlineView.activeNativeDragWriter = nil
                outlineView.activeNativeDragOwnerships = []
                outlineView.activeNativeDragSession = nil
            } else if let searchResultsView = activeNativeDragSourceView as? FileExplorerSearchResultsTableView {
                searchResultsView.activeNativeDragDelegateMarker = nil
                searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
                searchResultsView.activeNativeDragWriter = nil
                searchResultsView.activeNativeDragOwnerships = []
                searchResultsView.activeNativeDragSession = nil
            }
        }

        /// Reclaims the promoted source even when its original view is no
        /// longer the coordinator's current representable.
        @discardableResult
        func reclaimTrackedNativeDrag() -> Bool {
            guard let session = activeNativeDragSession else { return false }
            if activeNativeDragOwnerships.isEmpty {
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            } else {
                for ownership in activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            }
            let writer = activeNativeDragWriter
            clearTrackedSourceState()
            writer?.releaseSourceGraph()
            activeNativeDragSourceView = nil
            activeNativeDragWriter = nil
            activeNativeDragSession = nil
            activeNativeDragOwnerships = []
            return true
        }

        func isTrackingNativeDrag(_ session: NSDraggingSession) -> Bool {
            activeNativeDragSession === session
        }

        func forgetTrackedNativeDrag(matching session: NSDraggingSession) {
            guard activeNativeDragSession === session else { return }
            activeNativeDragSourceView = nil
            activeNativeDragWriter = nil
            activeNativeDragSession = nil
            activeNativeDragOwnerships = []
        }

        private func previewWriterDidDeallocate(tokenID: UUID) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView,
                  outlineView.pendingNativeDragTokenID == tokenID else { return }
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
        }

        // MARK: - Drag-to-Preview

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? FileExplorerNode, !node.isDirectory else { return nil }
            guard store.provider is LocalFileExplorerProvider else { return nil }
            let writer = FilePreviewDragPasteboardWriter(
                filePath: node.path,
                displayTitle: node.name,
                nativeSourceView: outlineView,
                // Retain the exact container/delegate graph through a
                // representable rebuild; the coordinator's container edge is
                // intentionally weak.
                nativeSourceOwner: containerView ?? outlineView,
                provisionalToken: pendingPreviewDrag.makeToken()
            )
            if let outlineView = outlineView as? FileExplorerNSOutlineView {
                outlineView.pendingNativeDragWriter = writer
                pendingPreviewDrag.register(writer)
                outlineView.pendingNativeDragTokenID = writer.provisionalToken?.id
            }
            return writer
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            _ = screenPoint
            _ = draggedItems
            if let outlineView = outlineView as? FileExplorerNSOutlineView {
                if outlineView.activeNativeDragSession === session {
                    return
                }
                if activeNativeDragSession === session {
                    return
                }
                // A distinct begin is a native boundary, even when the prior
                // source belonged to a rebuilt outline view.
                _ = reclaimTrackedNativeDrag()
                let fallbackWriter = outlineView.pendingNativeDragWriter
                var promotedWriters = pendingPreviewDrag.writers(for: outlineView)
                if let fallbackWriter,
                   !promotedWriters.contains(where: { $0 === fallbackWriter }) {
                    promotedWriters.append(fallbackWriter)
                }
                pendingPreviewDrag.finishPending(preserving: promotedWriters)
                supersedeNativeDragIfNeeded(
                    previousSession: outlineView.activeNativeDragSession,
                    newSession: session,
                    finishPrevious: {
                        let pasteboard = outlineView.activeNativeDragSession?.draggingPasteboard
                            ?? session.draggingPasteboard
                        for ownership in outlineView.activeNativeDragOwnerships {
                            ownership.finish(from: pasteboard)
                        }
                    },
                    clearPrevious: {
                        outlineView.activeNativeDragWriter?.releaseSourceGraph()
                        outlineView.activeNativeDragWriter = nil
                        outlineView.activeNativeDragDelegateMarker = nil
                        outlineView.activeNativeDragOwnerships = []
                        outlineView.activeNativeDragOwnership = nil
                        outlineView.activeNativeDragSession = nil
                    }
                )
                // The ordered list mirrors AppKit's pasteboard item order; use
                // its first writer as the canonical source identity.
                let promotedWriter = promotedWriters.first ?? fallbackWriter
                let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
                promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
                let ownerships = promotedOwnerships.isEmpty
                    ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
                    : promotedOwnerships
                outlineView.activeNativeDragDelegateMarker = self
                outlineView.activeNativeDragSession = session
                outlineView.activeNativeDragWriter = promotedWriter
                outlineView.activeNativeDragOwnerships = ownerships
                outlineView.pendingNativeDragWriter = nil
                outlineView.pendingNativeDragTokenID = nil
                trackNativeDrag(
                    sourceView: outlineView,
                    session: session,
                    writer: promotedWriter,
                    ownerships: ownerships
                )
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView,
                  outlineView.activeNativeDragSession === session else {
                // The delegate may have been rebuilt between writer creation
                // and the terminal callback. Use this session's own pasteboard
                // for idempotent capability cleanup; never inspect the
                // process-wide board here.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
                return
            }
            if !outlineView.activeNativeDragOwnerships.isEmpty {
                for ownership in outlineView.activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            } else {
                // The matching session identity proves this is not a stale
                // callback. Keep a compatibility fallback for an AppKit path
                // that released the plain writer before promotion.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            }
            outlineView.activeNativeDragDelegateMarker = nil
            outlineView.activeNativeDragWriter?.releaseSourceGraph()
            outlineView.activeNativeDragWriter = nil
            outlineView.activeNativeDragOwnerships = []
            outlineView.activeNativeDragOwnership = nil
            outlineView.activeNativeDragSession = nil
            forgetTrackedNativeDrag(matching: session)
        }

        /// Reclaims an outline drag at the next pointer boundary when AppKit
        /// omitted its native terminal callback during reconstruction. The
        /// exact outline argument matters because ``Coordinator.outlineView``
        /// may already point at a newly built view.
        func prepareForNativeDragBoundary(on outlineView: NSOutlineView) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView else { return }
            if reclaimTrackedNativeDrag() {
                // The tracked source may be an older outline retained by the
                // writer. Clear only this view's pending request; its active
                // state, if any, belongs to a separate generation.
                pendingPreviewDrag.finishPending()
                outlineView.pendingNativeDragWriter = nil
                outlineView.pendingNativeDragTokenID = nil
                return
            }
            guard let session = outlineView.activeNativeDragSession else {
                outlineView.activeNativeDragDelegateMarker = nil
                pendingPreviewDrag.finishPending()
                outlineView.pendingNativeDragWriter = nil
                if let tokenID = outlineView.pendingNativeDragTokenID {
                    pendingPreviewDrag.remove(tokenID: tokenID)
                }
                outlineView.pendingNativeDragTokenID = nil
                outlineView.activeNativeDragOwnership = nil
                return
            }
            for ownership in outlineView.activeNativeDragOwnerships {
                ownership.finish(from: session.draggingPasteboard)
            }
            pendingPreviewDrag.finishPending()
            outlineView.activeNativeDragDelegateMarker = nil
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
            outlineView.activeNativeDragWriter?.releaseSourceGraph()
            outlineView.activeNativeDragWriter = nil
            outlineView.activeNativeDragOwnerships = []
            outlineView.activeNativeDragOwnership = nil
            outlineView.activeNativeDragSession = nil
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
            GhosttyApp.terminalPasteboard.writeString(
                node.path,
                to: .general
            )
        }

        @objc private func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            let relativePath = FileExplorerTerminalPathInsertion.relativePath(for: node.path, rootPath: store.rootPath)
            GhosttyApp.terminalPasteboard.writeString(
                relativePath,
                to: .general
            )
        }
    }
}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and either the Files outline
/// or the Find panel.
@MainActor
final class FileExplorerContainerView: NSView {
    private let headerView: FileExplorerHeaderView
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    /// The Find mode's query bar and results. Hidden in the Files presentation.
    let findPanel: FileSearchPanelView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private var currentRootPath = ""
    var currentResourceContextID: UUID?
    private var currentWorkspaceRootIdentity: UUID?
    private var hasContent = false
    private var isLoading = false
    private var presentation: FileExplorerPanelPresentation
    let coordinator: FileExplorerPanelView.Coordinator
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    /// The Find results outline.
    var searchResultsView: FileExplorerSearchResultsTableView { findPanel.resultsView }

    private var isFindPresented: Bool { presentation == .find }

    /// - Parameter makeSearchSession: Builds per-workspace Find sessions.
    ///   Tests inject sessions with a manual clock.
    init(
        coordinator: FileExplorerPanelView.Coordinator,
        presentation: FileExplorerPanelPresentation,
        makeSearchSession: (() -> FileSearchSession)? = nil
    ) {
        headerView = FileExplorerHeaderView()
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        findPanel = FileSearchPanelView(coordinator: coordinator, makeSession: makeSearchSession ?? { FileSearchSession() })
        emptyLabel = NSTextField(wrappingLabelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)
        // Direct test/fixture construction bypasses NSViewRepresentable's
        // makeNSView hook; keep the coordinator's current-container identity
        // correct for native drag ownership in both paths.
        coordinator.containerView = self
        updateShortcutPlacement(coordinator.placement)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Find
        findPanel.translatesAutoresizingMaskIntoConstraints = false
        findPanel.isHidden = true
        findPanel.onDismiss = { [weak self] in self?.dismissFind() }
        findPanel.onFocus = { [weak self, weak coordinator] in
            guard let self else { return }
            coordinator?.noteKeyboardFocus(mode: .find, in: self.window)
        }
        addSubview(findPanel)

        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            self?.findPanel.applyFontScale()
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
        outlineView.onNativeDragPointerBoundary = { [weak coordinator, weak outlineView] in
            guard let outlineView else { return }
            coordinator?.prepareForNativeDragBoundary(on: outlineView)
        }
        outlineView.doubleAction = #selector(FileExplorerPanelView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        coordinator.outlineView = outlineView
        outlineView.onContextMenuDidClose = { [weak coordinator] in
            coordinator?.contextMenuDidClose()
        }

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

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            findPanel.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            findPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            findPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            findPanel.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateContentLayout()
        findPanel.setActive(isFindPresented)
    }

    private func applyChromeFonts() {
        emptyLabel.font = GlobalFontMagnification.systemFont(ofSize: 13)
        headerView.applyFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            findPanel.setActive(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if coordinator.placement == .rightSidebar {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
        }
        findPanel.setActive(isFindPresented)
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
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateHeader(store: FileExplorerStore) {
        currentRootPath = store.rootPath
        currentResourceContextID = store.resourceContextID
        currentWorkspaceRootIdentity = store.workspaceRootIdentity
        headerView.update(displayPath: store.displayRootPath,
            retry: store.provider is CloudVMFileExplorerProvider ? { [weak store] in store?.retryRemoteRoot() } : nil)
        findPanel.update(store: store)
    }

    func representedRightSidebarMode() -> RightSidebarMode {
        presentation.rightSidebarMode
    }

    func updateShortcutPlacement(_ placement: FileExplorerPanelPlacement) {
        findPanel.queryBar.queryField.fileExplorerPanelPlacement = placement
        outlineView.fileExplorerPanelPlacement = placement
        searchResultsView.fileExplorerPanelPlacement = placement
    }

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else { return }
        presentation = nextPresentation
        updateContentLayout()
        findPanel.setActive(isFindPresented)
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateVisibility(
        hasContent: Bool,
        isLoading: Bool,
        statusMessage: String?,
        showsRemoteTarget: Bool = false
    ) {
        let normalizedStatus = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStatus = normalizedStatus?.isEmpty == false
        let canShowTree = hasContent && !hasStatus
        self.hasContent = canShowTree
        self.isLoading = isLoading
        applyHidden(headerView, !hasContent && !hasStatus && !showsRemoteTarget)
        updateContentLayout()
        let findCanShow = isFindPresented && canShowTree && !isLoading
        let nextEmptyText = hasStatus
            ? normalizedStatus!
            : String(localized: "fileExplorer.empty", defaultValue: "No folder open")
        if emptyLabel.stringValue != nextEmptyText {
            emptyLabel.stringValue = nextEmptyText
        }
        applyHidden(emptyLabel, canShowTree || findCanShow || isLoading)
        // Toggle the spinner only when the loading state actually changes.
        if applyHidden(loadingIndicator, !isLoading) {
            if isLoading {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }
        }
    }

    /// Shows either the Files outline or the Find panel.
    private func updateContentLayout() {
        // Assigning isHidden unconditionally fires KVO even when unchanged,
        // which re-enters updateNSView and spins the main thread on macOS 26 (#4931).
        // Loading hides Find's results, not its query bar: hiding the field
        // that is being edited would end editing and drop shortcut focus.
        var changed = false
        if applyHidden(findPanel, !isFindPresented) { changed = true }
        if applyHidden(scrollView, isFindPresented || !hasContent || isLoading) { changed = true }
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

    /// Focuses Find's query field. A `seed` (the selection Find was invoked
    /// with) replaces the query and searches immediately.
    @discardableResult
    func focusSearchField(seed: String? = nil) -> Bool {
        guard window != nil, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.search.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        let result = findPanel.focusQueryField(seed: seed)
#if DEBUG
        dlog(
            "file.focus.search.end result=\(result ? 1 : 0) win=\(window?.windowNumber ?? -1) " +
            "seedLen=\(seed?.count ?? 0) fr=\(fileExplorerDebugResponder(window?.firstResponder))"
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
        if responder === outlineView { return true }
        return findPanel.ownsResponder(responder)
    }

    /// Escape in Find with nothing to clear hands focus back to the terminal.
    private func dismissFind() {
        if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
            return
        }
        window?.makeFirstResponder(nil)
    }

    /// Reclaims a Find drag whose terminal callback was lost.
    func prepareForNativeDragBoundary() {
        findPanel.prepareForNativeDragBoundary()
    }

    func clearNativeDragMarkersIfIdle() {
        findPanel.clearNativeDragMarkersIfIdle()
        guard outlineView.activeNativeDragSession == nil else { return }
        for ownership in outlineView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
    }
}
