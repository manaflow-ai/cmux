import AppKit
import SwiftUI

/// The Notes sidebar tab: the Files tree and the Vault combined for one
/// workspace — a real filesystem tree of its notes (workspace subtree plus the
/// project's flat `.cmux/notes/*.md` notes) with the workspace's recent agent
/// sessions as live rows beneath them.
///
/// Backed by an `NSOutlineView` (not SwiftUI), so list rows never hold an
/// `ObservableObject` reference — sidestepping the lazy-list CPU-spin class of
/// bug (see CLAUDE.md snapshot-boundary rule). Cross-boundary actions that need
/// app state the tree doesn't own (opening a note panel, resuming a session) are
/// injected as closures from the composition root.
struct NotesTreePanelView: NSViewRepresentable {
    @ObservedObject var store: NotesTreeStore
    /// Open a note file in a markdown surface.
    let onOpenNote: (NotesTreeNode, _ editImmediately: Bool) -> Void
    /// Resume the Claude session backing a session folder.
    let onResumeMarker: (NotesSessionMarker) -> Void

    static let movePasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move")
    /// Set on the drag pasteboard when the dragged item is a session folder, so
    /// the drop side can reject nesting a session under another session without
    /// reading the filesystem during drag-over.
    static let sessionFlagPasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move.session")
    /// A draggable session pointer (`NotesSessionDescriptor` JSON). Written by
    /// both the Vault session rows and Notes session folders, so a claude/codex/
    /// any session drags identically; dropping it on the Notes tree creates a
    /// session folder. Shared with `SessionIndexView`.
    static let sessionDragPasteboardType = NSPasteboard.PasteboardType("com.cmux.session-drag")
    /// Bonsplit's external tab-drop payload. Session folders carry it so they
    /// can be dropped onto a pane to resume, exactly like a Vault row.
    static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

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
        // Defer reloads while an inline rename is typing (reloadData would tear
        // the field editor down mid-edit); the rename's end flushes the miss.
        if container.appliedRevision != store.contentRevision, !coordinator.isRenaming {
            container.appliedRevision = store.contentRevision
            container.outlineView.reloadData()
            coordinator.applyExpansion(container.outlineView)
        }
        container.updateHeader(
            displayPath: store.headerDisplayPath,
            notesRootPath: store.resolvedRootPath,
            hasWorkspace: store.hasWorkspace
        )
        container.updateEmptyState(hasWorkspace: store.hasWorkspace, isEmpty: store.rootNodes.isEmpty)
    }

    // MARK: - Note drag writer

    /// Drag writer for note rows: composes the Files tab's file-preview writer
    /// (drag registry + bonsplit tab-transfer payload + fileURL, so dropping on
    /// a pane opens the markdown viewer and dragging out exports the file) with
    /// the notes-tree move type so in-tree drags stay filesystem moves.
    final class NoteDragWriter: NSObject, NSPasteboardWriting {
        private let movePath: String
        private let preview: FilePreviewDragPasteboardWriter

        init(filePath: String, displayTitle: String) {
            self.movePath = filePath
            self.preview = FilePreviewDragPasteboardWriter(filePath: filePath, displayTitle: displayTitle)
            super.init()
        }

        func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            [NotesTreePanelView.movePasteboardType] + preview.writableTypes(for: pasteboard)
        }

        func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            if type == NotesTreePanelView.movePasteboardType { return movePath }
            return preview.pasteboardPropertyList(forType: type)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var store: NotesTreeStore
        var onOpenNote: (NotesTreeNode, _ editImmediately: Bool) -> Void
        var onResumeMarker: (NotesSessionMarker) -> Void
        weak var container: NotesTreeContainerView?

        init(
            store: NotesTreeStore,
            onOpenNote: @escaping (NotesTreeNode, _ editImmediately: Bool) -> Void,
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

        /// Top level is the notes root's own children, exactly like the Files
        /// tree (the workspace path lives in the header bar, not in a row).
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

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            NotesTreeRowView()
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
            activate(node, in: sender)
        }

        func newNote(inFolder folder: String?) {
            guard let path = store.newNote(inFolder: folder) else { return }
            // Naming with Return opens the fresh note ready to type
            // (VSCode's new-file flow).
            revealAndRename(path: path, openOnReturn: true)
        }

        func newFolder(inFolder folder: String?) {
            guard let path = store.newFolder(inFolder: folder) else { return }
            revealAndRename(path: path)
        }

        /// Context-menu New Note/New Folder, node-aware: a virtual session row
        /// materializes its folder first so the new item lands inside it.
        func newNote(inContext node: NotesTreeNode?) {
            newNote(inFolder: mutationFolder(forContext: node))
        }

        func newFolder(inContext node: NotesTreeNode?) {
            newFolder(inFolder: mutationFolder(forContext: node))
        }

        private func mutationFolder(forContext node: NotesTreeNode?) -> String? {
            guard let node else { return nil }
            if node.isVirtual {
                guard let marker = node.kind.sessionMarker else { return nil }
                return store.materializeSession(marker)
            }
            return node.kind.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        }

        func refresh() { store.refreshFromUser() }

        func collapseAll() {
            store.collapseAll()
            reloadNow()
        }

        func open(_ node: NotesTreeNode) {
            switch node.kind {
            case .note: onOpenNote(node, false)
            case .sessionFolder(let marker): onResumeMarker(marker)
            case .folder: break
            }
        }

        /// Double-click and keyboard Return share this: open notes; click into
        /// directories like the Files tree. A session row with notes filed
        /// under it is a directory; a bare session row (virtual or empty) acts
        /// like a Vault row and resumes.
        func activate(_ node: NotesTreeNode, in outlineView: NSOutlineView) {
            switch node.kind {
            case .note:
                onOpenNote(node, false)
            case .sessionFolder(let marker) where !node.isExpandable:
                onResumeMarker(marker)
            case .folder, .sessionFolder:
                if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else {
                    outlineView.expandItem(node)
                }
            }
        }

        func resume(_ node: NotesTreeNode) {
            if case .sessionFolder(let marker) = node.kind { onResumeMarker(marker) }
        }

        func revealInFinder(_ node: NotesTreeNode) {
            guard !node.isVirtual else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        }

        func delete(_ node: NotesTreeNode) {
            guard !node.isVirtual else { return }
            if case .note = node.kind, !isTreeOwned(node) {
                // Index-owned flat note: delete through the flat store so the
                // index record and attachments are removed with the body.
                store.deleteFlatNote(path: node.path)
            } else {
                store.delete(path: node.path)
            }
            reloadNow()
        }

        // MARK: Rename / reveal

        /// True while an inline rename's field editor is live; reloads are
        /// deferred until it ends so the edit survives file-watcher churn
        /// (creating a note fires the very watcher that would reload the tree).
        private(set) var isRenaming = false

        /// Whether the tree owns this node's file (it lives in the workspace
        /// subtree). Flat notes are owned by the `.cmux/notes` index — renaming
        /// or moving their body file would orphan the index's `bodyPath` — so
        /// the tree offers them open/reveal/delete only.
        func isTreeOwned(_ node: NotesTreeNode) -> Bool {
            guard !node.isVirtual, let root = store.resolvedRootPath else { return false }
            return NotesTreeStorage.isWithin(child: node.path, orEqualTo: root)
        }

        func canRename(_ node: NotesTreeNode) -> Bool {
            node.kind.sessionMarker == nil && isTreeOwned(node)
        }

        /// Start a VSCode-style inline rename on the node's row. Session folders
        /// are not renamable (their label comes from the session marker), and
        /// neither are index-owned flat notes. With `openOnReturn`, a
        /// Return-committed rename of a note opens it.
        func beginRename(
            _ node: NotesTreeNode,
            in outlineView: NSOutlineView,
            openOnReturn: Bool = false
        ) {
            guard canRename(node) else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NotesTreeCellView
            else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isRenaming = true
            cell.beginRename(
                initialText: node.displayName,
                onCommit: { [weak self] newName, viaReturn in
                    guard let self else { return }
                    let renamed = self.store.rename(path: node.path, toName: newName)
                    self.reloadNow()
                    let currentPath = renamed ?? node.path
                    self.selectRow(forPath: currentPath)
                    if openOnReturn, viaReturn,
                       let named = self.findNode(path: currentPath), case .note = named.kind {
                        self.onOpenNote(named, true)
                    }
                },
                onEnded: { [weak self] in
                    guard let self else { return }
                    self.isRenaming = false
                    // Replay any reload deferred while the field editor was up.
                    // Async: this fires inside field-editor teardown, where a
                    // synchronous reloadData is fragile; a commit's own reload
                    // (if any) runs first and makes this a no-op.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isRenaming else { return }
                        if self.container?.appliedRevision != self.store.contentRevision {
                            self.reloadNow()
                        }
                    }
                }
            )
        }

        /// After creating an item: reload synchronously, make it visible, select
        /// it, and immediately offer an inline rename (VSCode's new-file flow).
        private func revealAndRename(path: String, openOnReturn: Bool = false) {
            store.expandAncestors(ofPath: path)
            reloadNow()
            selectRow(forPath: path)
            guard let container,
                  let node = findNode(path: path) else { return }
            beginRename(node, in: container.outlineView, openOnReturn: openOnReturn)
        }

        /// Synchronously mirror the store into the outline (used by mutations so
        /// follow-up row work targets fresh rows; `updateNSView` then sees a
        /// matching revision and skips the duplicate reload).
        func reloadNow() {
            guard let container else { return }
            container.appliedRevision = store.contentRevision
            container.outlineView.reloadData()
            applyExpansion(container.outlineView)
            container.updateEmptyState(hasWorkspace: store.hasWorkspace, isEmpty: store.rootNodes.isEmpty)
        }

        private func selectRow(forPath path: String) {
            guard let container, let node = findNode(path: path) else { return }
            let row = container.outlineView.row(forItem: node)
            guard row >= 0 else { return }
            container.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            container.outlineView.scrollRowToVisible(row)
        }

        private func findNode(path: String) -> NotesTreeNode? {
            let target = (path as NSString).standardizingPath
            func walk(_ nodes: [NotesTreeNode]) -> NotesTreeNode? {
                for node in nodes {
                    if (node.path as NSString).standardizingPath == target { return node }
                    if let children = node.children, let found = walk(children) { return found }
                }
                return nil
            }
            return walk(store.rootNodes)
        }

        // MARK: Drag-to-move

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? NotesTreeNode, !node.path.isEmpty else { return nil }
            // Notes drag like Files-tab files: the file-preview writer carries
            // the pane-drop payload (markdown viewer) and a fileURL. Tree-owned
            // notes compose the move type for in-tree drags; index-owned flat
            // notes must not move (the index's bodyPath would orphan), so they
            // drag as preview/export only.
            if case .note = node.kind {
                if isTreeOwned(node) {
                    return NotesTreePanelView.NoteDragWriter(filePath: node.path, displayTitle: node.displayName)
                }
                return FilePreviewDragPasteboardWriter(filePath: node.path, displayTitle: node.displayName)
            }
            let pbItem = NSPasteboardItem()
            // Virtual session rows have nothing on disk to move; they drag as
            // pure session pointers (still resumable on a pane / droppable in
            // another Notes tree, where they materialize).
            if !node.isVirtual {
                pbItem.setString(node.path, forType: NotesTreePanelView.movePasteboardType)
            }
            // Session rows also carry the shared session pointer (drag into
            // another Notes tree / window) and bonsplit's tab-transfer payload
            // (drop onto a pane to resume), exactly like a Vault row.
            if case .sessionFolder(let marker) = node.kind {
                if !node.isVirtual {
                    pbItem.setString("1", forType: NotesTreePanelView.sessionFlagPasteboardType)
                }
                let descriptor = NotesSessionDescriptor(
                    agent: marker.agent,
                    sessionId: marker.sessionId,
                    title: marker.title,
                    cwd: marker.cwd,
                    modified: marker.modified ?? 0
                )
                if let data = try? JSONEncoder().encode(descriptor) {
                    pbItem.setData(data, forType: NotesTreePanelView.sessionDragPasteboardType)
                }
                if let entry = marker.makeSessionEntry() {
                    let dragId = MainActor.assumeIsolated {
                        SessionDragRegistry.shared.register(entry)
                    }
                    if let transferData = sessionTabTransferData(for: entry, dragId: dragId) {
                        pbItem.setData(transferData, forType: NotesTreePanelView.tabTransferPasteboardType)
                    }
                }
            }
            return pbItem
        }

        // MARK: Drop handling

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            let pb = info.draggingPasteboard
            let destNode = item as? NotesTreeNode
            // Drop target must be a directory (folder/session) or the workspace root.
            if let destNode, !destNode.kind.isDirectory { return [] }
            guard let destFolder = destNode?.path ?? store.resolvedRootPath else { return [] }

            // Internal move of a note/folder/session already in this tree.
            if let source = pb.string(forType: NotesTreePanelView.movePasteboardType) {
                // A session folder must not be nested under another session.
                if pb.string(forType: NotesTreePanelView.sessionFlagPasteboardType) == "1",
                   let destNode, case .sessionFolder = destNode.kind {
                    return []
                }
                if NotesTreeStorage.isWithin(child: destFolder, orEqualTo: source) { return [] }
                if (source as NSString).deletingLastPathComponent == (destFolder as NSString).standardizingPath {
                    return []
                }
                outlineView.setDropItem(destNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }

            // External session pointer (dragged from the Vault or another window).
            if pb.availableType(from: [NotesTreePanelView.sessionDragPasteboardType]) != nil {
                // A session can't be nested under another session.
                if let destNode, case .sessionFolder = destNode.kind { return [] }
                outlineView.setDropItem(destNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }
            return []
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            let pb = info.draggingPasteboard
            let destNode = item as? NotesTreeNode
            // Dropping into a virtual session row materializes its folder
            // first, so "file this note under that session" is one gesture.
            let resolvedDest: String?
            if let destNode, destNode.isVirtual {
                guard let marker = destNode.kind.sessionMarker else { return false }
                resolvedDest = store.materializeSession(marker)
            } else {
                resolvedDest = destNode?.path ?? store.resolvedRootPath
            }
            guard let destFolder = resolvedDest else { return false }
            // Internal move wins (a Notes session folder carries both types, but
            // within the tree we move it rather than duplicate it).
            if let source = pb.string(forType: NotesTreePanelView.movePasteboardType) {
                guard let moved = store.move(sourcePath: source, intoFolder: destFolder) else { return false }
                reloadNow()
                selectRow(forPath: moved)
                return true
            }
            // External session pointer → create a session folder here.
            if let data = pb.data(forType: NotesTreePanelView.sessionDragPasteboardType),
               let descriptor = try? JSONDecoder().decode(NotesSessionDescriptor.self, from: data) {
                guard let added = store.addSession(descriptor, intoFolder: destFolder) else { return false }
                reloadNow()
                selectRow(forPath: added)
                return true
            }
            return false
        }
    }
}
