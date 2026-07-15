import AppKit

/// `NSOutlineView` subclass providing the per-row context menu and the same
/// keyboard model as the Files tree (j/k/h/l + arrows, Return to open,
/// ⌘⌫ to delete, sidebar mode shortcuts).
final class NotesTreeOutlineView: NSOutlineView {
    weak var coordinator: NotesTreePanelView.Coordinator?
    private var contextNode: NotesTreeNode?

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Route through the AppDelegate helper (like the Files tree) so the
        // user's configured `shortcuts.when` clauses gate mode switches here
        // too, instead of the default always-allowed matcher.
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if handleNavigationKey(event) { return }
        if isReturnKey(event), let node = selectedNode() {
            coordinator?.activate(node, in: self)
            return
        }
        if isCommandDelete(event), let node = selectedNode() {
            coordinator?.delete(node)
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNavigationKey(event) { return true }
        if isCommandDelete(event), let node = selectedNode() {
            coordinator?.delete(node)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            moveSelection(by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            performDisclosureAction(action)
            return true
        }
        return false
    }

    private func isReturnKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
        return event.keyCode == 36 || event.keyCode == 76
    }

    private func isCommandDelete(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command] && event.keyCode == 51
    }

    private func selectedNode() -> NotesTreeNode? {
        guard selectedRow >= 0 else { return nil }
        return item(atRow: selectedRow) as? NotesTreeNode
    }

    private func moveSelection(by delta: Int) {
        guard numberOfRows > 0 else { return }
        let current = selectedRow >= 0 ? selectedRow : (delta >= 0 ? -1 : numberOfRows)
        let target = min(max(current + delta, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        scrollRowToVisible(target)
    }

    private func performDisclosureAction(_ action: RightSidebarKeyboardNavigation.DisclosureAction) {
        guard let node = selectedNode() else { return }
        switch action {
        case .expand:
            if node.isExpandable, !isItemExpanded(node) { expandItem(node) }
        case .collapse:
            if node.isExpandable, isItemExpanded(node) {
                collapseItem(node)
            } else if let parent = parent(forItem: node) {
                let parentRow = row(forItem: parent)
                if parentRow >= 0 {
                    selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                    scrollRowToVisible(parentRow)
                }
            }
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let node = row >= 0 ? item(atRow: row) as? NotesTreeNode : nil
        contextNode = node
        let menu = NSMenu()

        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // The background (no row) gets the tree-level menu.
        guard let node else {
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.collapseAll", defaultValue: "Collapse All"), #selector(collapseAllContext))
            add(String(localized: "notes.action.refresh", defaultValue: "Refresh"), #selector(refreshContext))
            return menu
        }

        switch node.kind {
        case .note:
            add(String(localized: "notes.action.open", defaultValue: "Open"), #selector(openContext))
            // canRename is the single gate: tree-owned notes rename their
            // file, index-owned flat notes retitle their index record.
            if coordinator?.canRename(node) == true {
                add(String(localized: "notes.action.rename", defaultValue: "Rename"), #selector(renameContext))
            }
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .folder:
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            add(String(localized: "notes.action.rename", defaultValue: "Rename"), #selector(renameContext))
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .sessionFolder:
            add(String(localized: "notes.session.resume", defaultValue: "Resume session"), #selector(resumeContext))
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            // Virtual session rows have no folder on disk yet — nothing to
            // reveal or delete (filing a note materializes them).
            if !node.isVirtual {
                add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
                menu.addItem(.separator())
                add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
            }
        case .terminalFolder:
            // A live pane pointer: nothing on disk to mutate. Notes attach to
            // it via New Note on the surface or `cmux note new`.
            add(String(localized: "notes.terminal.focus", defaultValue: "Focus terminal"), #selector(focusTerminalContext))
        case .pastFolder:
            add(String(localized: "notes.action.collapseAll", defaultValue: "Collapse All"), #selector(collapseAllContext))
            add(String(localized: "notes.action.refresh", defaultValue: "Refresh"), #selector(refreshContext))
        }
        return menu
    }

    @objc private func openContext() { if let node = contextNode { coordinator?.open(node) } }
    @objc private func resumeContext() { if let node = contextNode { coordinator?.resume(node) } }
    @objc private func focusTerminalContext() {
        if let marker = contextNode?.kind.terminalMarker { coordinator?.focusTerminal(marker) }
    }
    @objc private func renameContext() { if let node = contextNode { coordinator?.beginRename(node, in: self) } }
    @objc private func revealContext() { if let node = contextNode { coordinator?.revealInFinder(node) } }
    @objc private func deleteContext() { if let node = contextNode { coordinator?.delete(node) } }
    @objc private func newNoteContext() { coordinator?.newNote(inContext: contextNode) }
    @objc private func newFolderContext() { coordinator?.newFolder(inContext: contextNode) }
    @objc private func collapseAllContext() { coordinator?.collapseAll() }
    @objc private func refreshContext() { coordinator?.refresh() }
}
