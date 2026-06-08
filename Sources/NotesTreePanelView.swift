import AppKit
import SwiftUI

/// The Notes sidebar tab: a real filesystem directory tree of the active
/// workspace's notes plus its Claude session folders.
///
/// Backed by an `NSOutlineView` (not SwiftUI), so list rows never hold an
/// `ObservableObject` reference — sidestepping the lazy-list CPU-spin class of
/// bug (see CLAUDE.md snapshot-boundary rule). Cross-boundary actions that need
/// app state the tree doesn't own (opening a note panel, resuming a session) are
/// injected as closures from the composition root.
struct NotesTreePanelView: NSViewRepresentable {
    @ObservedObject var store: NotesTreeStore
    /// Open a note file in a markdown surface.
    let onOpenNote: (NotesTreeNode) -> Void
    /// Resume the Claude session backing a session folder.
    let onResumeMarker: (NotesSessionMarker) -> Void

    static let movePasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move")
    /// Set on the drag pasteboard when the dragged item is a session folder, so
    /// the drop side can reject nesting a session under another session without
    /// reading the filesystem during drag-over.
    static let sessionFlagPasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move.session")

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onOpenNote: onOpenNote, onResumeMarker: onResumeMarker)
    }

    func makeNSView(context: Context) -> NotesTreeContainerView {
        let container = NotesTreeContainerView(coordinator: context.coordinator)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NotesTreeContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.onOpenNote = onOpenNote
        coordinator.onResumeMarker = onResumeMarker
        if container.appliedRevision != store.contentRevision {
            container.appliedRevision = store.contentRevision
            container.outlineView.reloadData()
            coordinator.applyExpansion(container.outlineView)
        }
        container.updateEmptyState(hasWorkspace: store.hasWorkspace, isEmpty: store.rootNodes.isEmpty)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var store: NotesTreeStore
        var onOpenNote: (NotesTreeNode) -> Void
        var onResumeMarker: (NotesSessionMarker) -> Void
        weak var container: NotesTreeContainerView?

        init(
            store: NotesTreeStore,
            onOpenNote: @escaping (NotesTreeNode) -> Void,
            onResumeMarker: @escaping (NotesSessionMarker) -> Void
        ) {
            self.store = store
            self.onOpenNote = onOpenNote
            self.onResumeMarker = onResumeMarker
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let kids = children(of: item)
            return index < kids.count ? kids[index] : NotesTreeNode(name: "", path: "\(index)", kind: .note)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? NotesTreeNode)?.isExpandable ?? false
        }

        private func children(of item: Any?) -> [NotesTreeNode] {
            guard let item else { return store.rootNodes }
            return (item as? NotesTreeNode)?.children ?? []
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? NotesTreeNode else { return nil }
            let cell = outlineView.makeView(
                withIdentifier: NotesTreeCellView.reuseIdentifier, owner: self
            ) as? NotesTreeCellView ?? {
                let view = NotesTreeCellView()
                view.identifier = NotesTreeCellView.reuseIdentifier
                return view
            }()
            cell.configure(with: node, style: FileExplorerStyle.current)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            FileExplorerStyle.current.rowHeight
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            if let node = item as? NotesTreeNode { store.setExpanded(node, expanded: true) }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            if let node = item as? NotesTreeNode { store.setExpanded(node, expanded: false) }
            return true
        }

        /// Re-apply persisted expansion after a reload (node objects are rebuilt
        /// each load, so the outline cannot restore expansion by identity).
        func applyExpansion(_ outlineView: NSOutlineView) {
            func walk(_ nodes: [NotesTreeNode]) {
                for node in nodes where node.isExpandable {
                    if store.isExpanded(node) {
                        outlineView.expandItem(node)
                        if let children = node.children { walk(children) }
                    }
                }
            }
            walk(store.rootNodes)
        }

        // MARK: Actions

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? NotesTreeNode else { return }
            switch node.kind {
            case .note:
                onOpenNote(node)
            case .sessionFolder(let marker):
                // Primary action for a session is Resume; expand via the
                // disclosure triangle (or the context menu).
                onResumeMarker(marker)
            case .folder:
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
            }
        }

        /// The directory a "new note/folder" action should target: the clicked
        /// row's directory (or its parent), else the workspace root (nil).
        func targetFolder(forRow row: Int, in outlineView: NSOutlineView) -> String? {
            guard row >= 0, let node = outlineView.item(atRow: row) as? NotesTreeNode else { return nil }
            if node.kind.isDirectory { return node.path }
            return (node.path as NSString).deletingLastPathComponent
        }

        func newNote(inFolder folder: String?) { store.newNote(inFolder: folder) }
        func newFolder(inFolder folder: String?) { store.newFolder(inFolder: folder) }
        func refresh() { store.reloadIfNeeded() }

        func open(_ node: NotesTreeNode) {
            switch node.kind {
            case .note: onOpenNote(node)
            case .sessionFolder(let marker): onResumeMarker(marker)
            case .folder: break
            }
        }

        func resume(_ node: NotesTreeNode) {
            if case .sessionFolder(let marker) = node.kind { onResumeMarker(marker) }
        }

        func revealInFinder(_ node: NotesTreeNode) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        }

        func delete(_ node: NotesTreeNode) {
            store.delete(path: node.path)
        }

        // MARK: Drag-to-move

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? NotesTreeNode, !node.path.isEmpty else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(node.path, forType: NotesTreePanelView.movePasteboardType)
            // Notes, plain folders, and session folders are all draggable; tag
            // sessions so a drop onto another session can be rejected.
            if case .sessionFolder = node.kind {
                pbItem.setString("1", forType: NotesTreePanelView.sessionFlagPasteboardType)
            }
            return pbItem
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let source = info.draggingPasteboard.string(forType: NotesTreePanelView.movePasteboardType) else {
                return []
            }
            let destNode = item as? NotesTreeNode
            if let destNode, !destNode.kind.isDirectory { return [] }
            // A session folder must not be nested under another session.
            if info.draggingPasteboard.string(forType: NotesTreePanelView.sessionFlagPasteboardType) == "1",
               let destNode, case .sessionFolder = destNode.kind {
                return []
            }
            guard let destFolder = destNode?.path ?? store.resolvedRootPath else { return [] }
            // Reject dropping a directory onto itself or a descendant, and a no-op
            // move into the item's current parent.
            if NotesTreeStorage.isWithin(child: destFolder, orEqualTo: source) { return [] }
            if (source as NSString).deletingLastPathComponent == (destFolder as NSString).standardizingPath {
                return []
            }
            outlineView.setDropItem(destNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let source = info.draggingPasteboard.string(forType: NotesTreePanelView.movePasteboardType) else {
                return false
            }
            let destNode = item as? NotesTreeNode
            guard let destFolder = destNode?.path ?? store.resolvedRootPath else { return false }
            return store.move(sourcePath: source, intoFolder: destFolder) != nil
        }
    }
}
