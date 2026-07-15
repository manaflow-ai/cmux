import AppKit

/// Data source, delegate, and action target for the Notes outline view: tree
/// mutations (new note/folder, rename, delete, drag-to-move) go through the
/// store it holds, while cross-boundary actions (opening a note panel,
/// resuming a session, focusing a terminal) run through closures injected by
/// ``NotesTreePanelView`` from the composition root.
final class NotesTreePanelCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var store: NotesTreeStore
    var onOpenNote: (NotesTreeNode, _ editImmediately: Bool) -> Void
    var onResumeMarker: (NotesSessionMarker) -> Void
    var onFocusTerminalPanel: (UUID) -> Void
    var onResolveTerminalNoteTarget: (NotesTreeObservedTerminal) -> CmuxNoteAttachmentTarget?
    weak var container: NotesTreeContainerView?

    init(
        store: NotesTreeStore,
        onOpenNote: @escaping (NotesTreeNode, _ editImmediately: Bool) -> Void,
        onResumeMarker: @escaping (NotesSessionMarker) -> Void,
        onFocusTerminalPanel: @escaping (UUID) -> Void,
        onResolveTerminalNoteTarget: @escaping (NotesTreeObservedTerminal) -> CmuxNoteAttachmentTarget?
    ) {
        self.store = store
        self.onOpenNote = onOpenNote
        self.onResumeMarker = onResumeMarker
        self.onFocusTerminalPanel = onFocusTerminalPanel
        self.onResolveTerminalNoteTarget = onResolveTerminalNoteTarget
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
        if case .pastFolder = node.kind { return nil }
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
        case .terminalFolder(let marker): focusTerminal(marker)
        case .folder, .pastFolder: break
        }
    }

    /// Double-click and keyboard Return share this: open notes; click into
    /// directories like the Files tree. A session row with notes filed
    /// under it is a directory; a bare session row (virtual or empty) acts
    /// like a Vault row and resumes. Terminal rows behave the same way:
    /// empty ones are pure pointers that focus their panel, ones with
    /// content expand.
    func activate(_ node: NotesTreeNode, in outlineView: NSOutlineView) {
        switch node.kind {
        case .note:
            onOpenNote(node, false)
        case .sessionFolder(let marker) where !node.isExpandable:
            onResumeMarker(marker)
        case .terminalFolder(let marker) where !node.isExpandable:
            focusTerminal(marker)
        case .folder, .sessionFolder, .terminalFolder, .pastFolder:
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

    func focusTerminal(_ marker: NotesTreeObservedTerminal) {
        guard let panelId = UUID(uuidString: marker.panelId) else { return }
        onFocusTerminalPanel(panelId)
    }

    func revealInFinder(_ node: NotesTreeNode) {
        guard !node.isVirtual else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func delete(_ node: NotesTreeNode) {
        guard !node.isVirtual else { return }
        if case .note = node.kind, store.isIndexedNote(path: node.path) {
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
    /// or moving their body file directly would orphan the index's
    /// `bodyPath` — so the tree mutates them through the flat store
    /// instead (move relocates the body, rename retitles the record).
    func isTreeOwned(_ node: NotesTreeNode) -> Bool {
        guard !node.isVirtual, let root = store.resolvedRootPath else { return false }
        return NotesTreeStorage.isWithin(child: node.path, orEqualTo: root)
    }

    /// Session folders are not renamable (their label comes from the
    /// session marker, which cmux keeps synced to the live session).
    /// Tree-owned files rename on disk; index-owned flat notes rename by
    /// retitling their index record (the tree displays the record title).
    func canRename(_ node: NotesTreeNode) -> Bool {
        guard node.kind.sessionMarker == nil, !node.isVirtual else { return false }
        if case .note = node.kind { return true }
        return isTreeOwned(node)
    }

    /// Start a VSCode-style inline rename on the node's row. Session folders
    /// are not renamable (their label comes from the session marker). With
    /// `openOnReturn`, a Return-committed rename of a note opens it.
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
                let renamed = self.store.isIndexedNote(path: node.path)
                    ? self.store.renameFlatNote(path: node.path, toTitle: newName)
                    : self.store.rename(path: node.path, toName: newName)
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
                Task { @MainActor [weak self] in
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

    private func moveSource(from pasteboard: NSPasteboard) -> (path: String, node: NotesTreeNode)? {
        guard let source = pasteboard.string(forType: NotesTreePanelView.movePasteboardType),
              let node = findNode(path: source),
              !node.isVirtual,
              store.isMutablePath(node.path)
        else { return nil }
        switch node.kind {
        case .note, .folder, .sessionFolder:
            return (node.path, node)
        case .terminalFolder, .pastFolder:
            return nil
        }
    }

    // MARK: Drag-to-move

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? NotesTreeNode, !node.path.isEmpty else { return nil }
        if case .pastFolder = node.kind { return nil }
        // Terminal rows are pure pointers: nothing on disk to move and no
        // session payload to carry, so they don't drag.
        if case .terminalFolder = node.kind { return nil }
        // Note rows drag with the full Files-tab payload (fileURL +
        // preview transfer types) so terminal drops insert the path or
        // open the preview, with Shift toggling the alternate. The window
        // file-drop overlay defers over this tree
        // (SidebarFileDropDeferralRegistry), so those types no longer
        // swallow in-sidebar moves. Folder/session rows stay cmux-private.
        if case .note = node.kind {
            return NotesTreePanelView.NoteDragWriter(filePath: node.path, displayTitle: node.displayName)
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

    /// Drops aimed at a note retarget to the note's parent directory
    /// (Files-style) instead of being rejected — dragging "onto" a row
    /// inside a session must file into that session.
    private func dropDestination(for item: Any?, in outlineView: NSOutlineView) -> NotesTreeNode? {
        guard let node = item as? NotesTreeNode else { return nil }
        if node.kind.isDirectory { return node }
        return outlineView.parent(forItem: node) as? NotesTreeNode
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pb = info.draggingPasteboard
        let destNode = dropDestination(for: item, in: outlineView)
        if let destNode, case .pastFolder = destNode.kind { return [] }
        if let destNode, case .terminalFolder = destNode.kind {
            guard let source = moveSource(from: pb),
                  case .note = source.node.kind else { return [] }
            outlineView.setDropItem(destNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard let destFolder = destNode?.path ?? store.resolvedRootPath else { return [] }

        // Internal move of a note/folder/session already in this tree.
        if let source = moveSource(from: pb) {
            // A session folder must not be nested under another session.
            if case .sessionFolder = source.node.kind,
               let destNode, case .sessionFolder = destNode.kind {
                return []
            }
            if NotesTreeStorage.isWithin(child: destFolder, orEqualTo: source.path) { return [] }
            if (source.path as NSString).deletingLastPathComponent == (destFolder as NSString).standardizingPath {
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
        let destNode = dropDestination(for: item, in: outlineView)
        if let destNode, case .pastFolder = destNode.kind { return false }
        if let destNode, case .terminalFolder(let terminal) = destNode.kind {
            guard let source = moveSource(from: pb),
                  case .note = source.node.kind,
                  let target = onResolveTerminalNoteTarget(terminal),
                  let attached = store.attachNote(path: source.path, toTerminal: terminal, target: target)
            else { return false }
            reloadNow()
            selectRow(forPath: attached)
            return true
        }
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
        // within the tree we move it rather than duplicate it). Index-owned
        // flat notes route through the flat store so the index's bodyPath
        // moves with the file.
        if let source = moveSource(from: pb) {
            let treeOwnedSource = isTreeOwned(source.node)
            let moved = treeOwnedSource
                ? store.move(sourcePath: source.path, intoFolder: destFolder)
                : store.moveFlatNote(path: source.path, intoFolder: destFolder)
            guard let moved else { return false }
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
