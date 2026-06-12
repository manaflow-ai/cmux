import AppKit

extension FileExplorerPanelView.Coordinator {
    func openSelectedNode(in outlineView: NSOutlineView) {
        guard let row = resolvedSelectionRow(in: outlineView) else { return }
        openNode(in: outlineView, at: row)
    }

    func openNode(in outlineView: NSOutlineView, at row: Int) {
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileExplorerNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else if outlineView.isExpandable(node) {
                outlineView.expandItem(node)
            }
            return
        }

        guard store.provider is LocalFileExplorerProvider else { return }
        onOpenFilePreview(node.path)
    }
}

extension FileExplorerNSOutlineView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard Self.isOpenSelectionShortcut(event) else { return false }
        endQuickSearch()
        fileExplorerCoordinator?.openSelectedNode(in: self)
        return true
    }

    private static func isOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        openSelectionShortcutActions.contains { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: event) &&
                (AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true)
        }
    }

    private static var openSelectionShortcutActions: [KeyboardShortcutSettings.Action] {
        [.fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias]
    }
}
