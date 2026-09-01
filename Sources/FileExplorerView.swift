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
        private var observationCancellable: AnyCancellable?
        private var styleObserver: Any?
        private var isUpdatingOutlineProgrammatically = false
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

        fileprivate func trackNativeDrag(
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
        fileprivate func reclaimTrackedNativeDrag() -> Bool {
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

        fileprivate func isTrackingNativeDrag(_ session: NSDraggingSession) -> Bool {
            activeNativeDragSession === session
        }

        fileprivate func forgetTrackedNativeDrag(matching session: NSDraggingSession) {
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
    private var searchFieldHeightConstraint: NSLayoutConstraint!
    private(set) var searchSnapshot = FileSearchSnapshot.empty
    private var currentRootPath = ""
    private var currentProviderIsLocal = false
    private var currentWorkspaceRootIdentity: UUID?
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
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
        self?.previewWriterDidDeallocate(tokenID: tokenID)
    }
    private let searchDebounceDelayMilliseconds = 200
    private var searchBarVisibleHeight: CGFloat { max(48, GlobalFontMagnification.scaled(48)) }
    private var searchFieldVisibleHeight: CGFloat { max(24, GlobalFontMagnification.scaled(24)) }

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
        // Direct test/fixture construction bypasses NSViewRepresentable's
        // makeNSView hook; keep the coordinator's current-container identity
        // correct for native drag ownership in both paths.
        coordinator.containerView = self
        updateShortcutPlacement(coordinator.placement)
        configureSearchDebounce()

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
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.lineBreakMode = .byTruncatingTail
        searchStatusLabel.maximumNumberOfLines = 1
        searchStatusLabel.alignment = .left
        searchStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBarView.addSubview(searchStatusLabel)

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
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
        }
        searchResultsView.onModeShortcut = { [weak coordinator] mode, window in
            coordinator?.handleModeShortcut(mode, in: window) ?? false
        }
        searchResultsView.onNativeDragPointerBoundary = { [weak self] in
            self?.prepareForNativeDragBoundary()
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
        searchFieldHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: searchFieldVisibleHeight)
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
            searchFieldHeightConstraint,
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

    private func applyChromeFonts() {
        searchField.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .regular)
        searchStatusLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        emptyLabel.font = GlobalFontMagnification.systemFont(ofSize: 13)
        searchFieldHeightConstraint?.constant = searchFieldVisibleHeight
        if isSearchVisible {
            searchBarHeightConstraint?.constant = searchBarVisibleHeight
        }
        headerView.applyFonts()
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
        let nextRootPath = store.rootPath, nextProviderIsLocal = store.provider is LocalFileExplorerProvider
        let nextWorkspaceRootIdentity = store.workspaceRootIdentity, nextContentRevision = store.contentRevision
        let workspaceRootChanged = nextWorkspaceRootIdentity != currentWorkspaceRootIdentity, contentRevisionChanged = nextContentRevision != currentContentRevision
        let searchScopeChanged = workspaceRootChanged || nextRootPath != currentRootPath || nextProviderIsLocal != currentProviderIsLocal
        currentRootPath = nextRootPath; currentProviderIsLocal = nextProviderIsLocal
        currentWorkspaceRootIdentity = nextWorkspaceRootIdentity; currentContentRevision = nextContentRevision
        headerView.update(displayPath: store.displayRootPath)
        if workspaceRootChanged { cancelPendingSearchRefresh(); pendingSearchRefreshAfterSettled = false; searchController.cancel(clear: true); searchField.stringValue = ""; applySearchSnapshot(.empty) }
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

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else {
            // Re-selecting the active presentation is a no-op unless visibility drifted.
            if presentation == .find, !isSearchVisible {
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
        applyHidden(headerView, !hasContent && !hasStatus)
        updateSearchLayout(hasContent: canShowTree, isLoading: isLoading)
        let searchCanShow = isSearchVisible && canShowTree && !isLoading
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
        let nextSearchBarHeight = showSearch ? searchBarVisibleHeight : 0

        // Assigning isHidden/constraints unconditionally fires KVO even when unchanged,
        // which re-enters updateNSView and spins the main thread on macOS 26 (#4931).
        var changed = false
        if applyHidden(searchBarView, !showSearch) { changed = true }
        if searchBarHeightConstraint.constant != nextSearchBarHeight {
            searchBarHeightConstraint.constant = nextSearchBarHeight
            changed = true
        }
        if applyHidden(searchScrollView, !showSearch) { changed = true }
        if applyHidden(scrollView, showSearch || !effectiveHasContent || effectiveIsLoading) { changed = true }
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

    @MainActor
    fileprivate func openSelectedSearchResult() {
        let row = searchResultsView.selectedRow
        guard row >= 0, row < searchSnapshot.results.count else { return }
        let path = searchSnapshot.results[row].path
        // Editor/preferred-editor actions operate on local file paths via
        // NSWorkspace; for non-local providers fall back to the cmux preview.
        guard coordinator.store.provider is LocalFileExplorerProvider else {
            coordinator.onOpenFilePreview(path)
            return
        }
        performFileExplorerFileOpen(path: path, onOpenFilePreview: coordinator.onOpenFilePreview)
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
        GhosttyApp.terminalPasteboard.writeString(
            result.path,
            to: .general
        )
    }

    @objc private func contextMenuCopySearchResultRelativePath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        GhosttyApp.terminalPasteboard.writeString(
            result.relativePath,
            to: .general
        )
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
        guard control === searchField, !textView.hasMarkedText() else { return false }
        if let event = NSApp.currentEvent, searchField.handleOpenSelectionShortcut(event) { return true }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
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

    private func previewWriterDidDeallocate(tokenID: UUID) {
        guard searchResultsView.pendingNativeDragTokenID == tokenID else { return }
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
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
        let writer = FilePreviewDragPasteboardWriter(
            filePath: result.path,
            displayTitle: (result.relativePath as NSString).lastPathComponent,
            nativeSourceView: tableView,
            nativeSourceOwner: self,
            provisionalToken: pendingPreviewDrag.makeToken()
        )
        searchResultsView.pendingNativeDragWriter = writer
        searchResultsView.pendingNativeDragTokenID = writer.provisionalToken?.id
        pendingPreviewDrag.register(writer)
        return writer
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        _ = screenPoint
        _ = rowIndexes
        guard tableView === searchResultsView else { return }
        if let previousSession = searchResultsView.activeNativeDragSession,
           previousSession === session {
            return
        }
        if coordinator.isTrackingNativeDrag(session) {
            return
        }
        // A distinct begin is a native boundary, including when the previous
        // source belonged to a container replaced by SwiftUI reconstruction.
        _ = coordinator.reclaimTrackedNativeDrag()
        let fallbackWriter = searchResultsView.pendingNativeDragWriter
        var promotedWriters = pendingPreviewDrag.writers(for: tableView)
        if let fallbackWriter,
           !promotedWriters.contains(where: { $0 === fallbackWriter }) {
            promotedWriters.append(fallbackWriter)
        }
        pendingPreviewDrag.finishPending(preserving: promotedWriters)
        coordinator.supersedeNativeDragIfNeeded(
            previousSession: searchResultsView.activeNativeDragSession,
            newSession: session,
            finishPrevious: {
                let pasteboard = searchResultsView.activeNativeDragSession?.draggingPasteboard
                    ?? session.draggingPasteboard
                for ownership in searchResultsView.activeNativeDragOwnerships {
                    ownership.finish(from: pasteboard)
                }
            },
            clearPrevious: {
                searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
                searchResultsView.activeNativeDragWriter = nil
                searchResultsView.activeNativeDragDelegateMarker = nil
                searchResultsView.activeNativeDragOwnerships = []
                searchResultsView.activeNativeDragOwnership = nil
                searchResultsView.activeNativeDragSession = nil
            }
        )
        // The ordered list mirrors AppKit's pasteboard item order; use its
        // first writer as the canonical source identity.
        let promotedWriter = promotedWriters.first ?? fallbackWriter
        let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
        promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
        let ownerships = promotedOwnerships.isEmpty
            ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
            : promotedOwnerships
        // The pasteboard writer retains this exact container through the native
        // terminal callback. Keep only a weak marker on the table: a strong
        // table → container edge would create a retain cycle.
        searchResultsView.activeNativeDragDelegateMarker = self
        searchResultsView.activeNativeDragWriter = promotedWriter
        searchResultsView.activeNativeDragOwnerships = ownerships
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
        searchResultsView.activeNativeDragSession = session
        coordinator.trackNativeDrag(
            sourceView: searchResultsView,
            session: session,
            writer: promotedWriter,
            ownerships: ownerships
        )
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard tableView === searchResultsView else { return }
        if searchResultsView.activeNativeDragSession === session {
            if !searchResultsView.activeNativeDragOwnerships.isEmpty {
                for ownership in searchResultsView.activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            } else {
                // This is the matching generation, so the fallback cannot
                // accidentally parse a newer session's shared pasteboard.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            }
            searchResultsView.activeNativeDragDelegateMarker = nil
            searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
            searchResultsView.activeNativeDragWriter = nil
            searchResultsView.activeNativeDragOwnerships = []
            searchResultsView.activeNativeDragOwnership = nil
            searchResultsView.activeNativeDragSession = nil
            coordinator.forgetTrackedNativeDrag(matching: session)
        }
    }

    /// Reclaims a search drag whose native terminal callback was lost before a
    /// subsequent pointer gesture. AppKit cannot deliver this `mouseDown`
    /// while the prior native drag loop is active, making the boundary safe to
    /// use for releasing the intentional container/table retain cycle.
    func prepareForNativeDragBoundary() {
        if coordinator.reclaimTrackedNativeDrag() {
            // The coordinator may be tracking an outline or search table from
            // an older container. Finish pending writers owned by this
            // container as well, without touching a new active generation.
            pendingPreviewDrag.finishPending()
            searchResultsView.pendingNativeDragWriter = nil
            searchResultsView.pendingNativeDragTokenID = nil
            return
        }
        guard let session = searchResultsView.activeNativeDragSession else {
            searchResultsView.activeNativeDragDelegateMarker = nil
            pendingPreviewDrag.finishPending()
            if let tokenID = searchResultsView.pendingNativeDragTokenID {
                pendingPreviewDrag.remove(tokenID: tokenID)
            }
            searchResultsView.pendingNativeDragWriter = nil
            searchResultsView.pendingNativeDragTokenID = nil
            searchResultsView.activeNativeDragOwnership = nil
            return
        }
        for ownership in searchResultsView.activeNativeDragOwnerships {
            ownership.finish(from: session.draggingPasteboard)
        }
        pendingPreviewDrag.finishPending()
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
        searchResultsView.activeNativeDragDelegateMarker = nil
        searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
        searchResultsView.activeNativeDragWriter = nil
        searchResultsView.activeNativeDragOwnerships = []
        searchResultsView.activeNativeDragOwnership = nil
        searchResultsView.activeNativeDragSession = nil
        coordinator.forgetTrackedNativeDrag(matching: session)
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

        FileExplorerExternalOpenMenuItems(
            fileURL: URL(fileURLWithPath: searchSnapshot.results[row].path),
            target: self,
            action: #selector(contextMenuOpenSearchResultExternally(_:))
        ).add(to: menu)

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

private extension FileExplorerContainerView {
    func clearNativeDragMarkersIfIdle() {
        guard searchResultsView.activeNativeDragSession == nil,
              outlineView.activeNativeDragSession == nil else { return }
        for ownership in searchResultsView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        for ownership in outlineView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        searchResultsView.activeNativeDragDelegateMarker = nil
        searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
        searchResultsView.activeNativeDragWriter = nil
        searchResultsView.activeNativeDragOwnerships = []
        searchResultsView.activeNativeDragOwnership = nil
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
    }
}
