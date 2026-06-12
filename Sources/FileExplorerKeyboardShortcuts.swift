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
        guard event.isFileExplorerOpenSelectionShortcut else { return false }
        endQuickSearch()
        fileExplorerCoordinator?.openSelectedNode(in: self)
        return true
    }
}

extension FileExplorerSearchResultsTableView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut else { return false }
        onCommit?()
        return true
    }
}

extension FileExplorerSearchField {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut else { return false }
        onCommit?()
        return true
    }
}

extension NSEvent {
    var isFileExplorerOpenSelectionShortcut: Bool {
        KeyboardShortcutSettings.Action.fileExplorerOpenSelectionActions.contains { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: self) &&
                (AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: self) ?? true)
        }
    }
}

private extension KeyboardShortcutSettings.Action {
    static var fileExplorerOpenSelectionActions: [Self] {
        [.fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias]
    }
}
