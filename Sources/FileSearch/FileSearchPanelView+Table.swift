import AppKit
import CmuxFileSearch

// Results table data source, delegate and context menu.
extension FileSearchPanelView: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        session.rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: FileSearchResultRowView.reuseIdentifier, owner: nil)
            as? FileSearchResultRowView ?? FileSearchResultRowView()
        rowView.identifier = FileSearchResultRowView.reuseIdentifier
        rowView.accentColor = accent.color
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let target = item(atRow: row)
        if let file = target as? FileSearchFileNode {
            let cell = tableView.makeView(withIdentifier: FileSearchFileCellView.reuseIdentifier, owner: nil)
                as? FileSearchFileCellView ?? FileSearchFileCellView(frame: .zero)
            cell.configure(with: file)
            cell.onToggle = { [weak self, weak file] in
                guard let self, let file else { return }
                self.setExpanded(!file.isExpanded, file: file)
            }
            return cell
        }
        if let node = target as? FileSearchMatchNode {
            let cell = tableView.makeView(withIdentifier: FileSearchMatchCellView.reuseIdentifier, owner: nil)
                as? FileSearchMatchCellView ?? FileSearchMatchCellView(frame: .zero)
            cell.configure(with: node, accent: accent.color)
            return cell
        }
        return nil
    }

    // MARK: - Context menu

    /// The results a context-menu action applies to: the selection when the
    /// clicked row is part of it, otherwise the clicked row.
    func menuResults(forRow row: Int) -> [FileSearchFileNode] {
        guard row >= 0 else { return [] }
        let rows = resultsView.selectedRowIndexes.contains(row) ? Array(resultsView.selectedRowIndexes) : [row]
        var seen = Set<String>()
        return rows.compactMap { self.file(atRow: $0) }.filter { seen.insert($0.path).inserted }
    }

    func file(atRow row: Int) -> FileSearchFileNode? {
        let target = item(atRow: row)
        return (target as? FileSearchFileNode) ?? (target as? FileSearchMatchNode)?.file
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === resultsView.menu else { return }
        menu.removeAllItems()
        let clickedRow = resultsView.clickedRow
        let row = clickedRow >= 0 ? clickedRow : resultsView.selectedRow
        guard resourceContextID == coordinator.store.resourceContextID,
              let target = item(atRow: row),
              let file = self.file(atRow: row) else { return }
        if clickedRow >= 0, !resultsView.selectedRowIndexes.contains(clickedRow) {
            resultsView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let rowNumber = NSNumber(value: row)
        let isLocal = coordinator.store.provider is LocalFileExplorerProvider

        addItem(to: menu, title: String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in cmux"),
                action: #selector(menuOpenInCmux(_:)), represented: target)
        if isLocal {
            FileExplorerExternalOpenMenuItems(
                fileURL: URL(fileURLWithPath: file.path),
                target: self,
                action: #selector(menuOpenExternally(_:))
            ).add(to: menu)
            addItem(to: menu, title: FileExternalOpenText.revealInFinder,
                    action: #selector(menuRevealInFinder(_:)), represented: rowNumber)
        }
        menu.addItem(.separator())
        menu.addFileExplorerInsertPathItems(
            target: self,
            representedObject: rowNumber,
            insertAction: #selector(menuInsertPath(_:)),
            insertRelativeAction: #selector(menuInsertRelativePath(_:))
        )
        addItem(to: menu, title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
                action: #selector(menuCopyPath(_:)), represented: rowNumber)
        addItem(to: menu, title: String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
                action: #selector(menuCopyRelativePath(_:)), represented: rowNumber)
        if target is FileSearchFileNode {
            menu.addItem(.separator())
            addItem(to: menu, title: String(localized: "fileSearch.action.dismissFile", defaultValue: "Dismiss"),
                    action: #selector(menuDismiss(_:)), represented: rowNumber)
        }
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, represented: Any) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        menu.addItem(item)
    }

    private func menuRow(_ sender: NSMenuItem) -> Int? {
        guard resourceContextID == coordinator.store.resourceContextID else { return nil }
        return (sender.representedObject as? NSNumber)?.intValue
    }

    @objc private func menuOpenInCmux(_ sender: NSMenuItem) {
        guard resourceContextID == coordinator.store.resourceContextID else { return }
        if let node = sender.representedObject as? FileSearchMatchNode {
            requestReveal(for: node.file, match: node.match)
            coordinator.onOpenFilePreview(node.file.path)
        } else if let file = sender.representedObject as? FileSearchFileNode {
            requestReveal(for: file, match: file.matches.first)
            coordinator.onOpenFilePreview(file.path)
        }
    }

    private func requestReveal(for file: FileSearchFileNode, match: FileSearchMatch?) {
        guard let match else { return }
        FilePreviewRevealCenter.shared.request(
            FilePreviewRevealLocation(line: match.lineNumber, column: match.column, length: match.length),
            forPath: file.path
        )
    }

    @objc private func menuOpenExternally(_ sender: NSMenuItem) {
        guard coordinator.store.provider is LocalFileExplorerProvider,
              let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
        FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        guard coordinator.store.provider is LocalFileExplorerProvider,
              let row = menuRow(sender), let file = file(atRow: row) else { return }
        FileExternalOpenAction.revealInFinder(fileURL: URL(fileURLWithPath: file.path))
    }

    @objc private func menuInsertPath(_ sender: NSMenuItem) {
        guard let row = menuRow(sender) else { return }
        FileExplorerTerminalPathInsertion.insert(paths: menuResults(forRow: row).map(\.path), intoTerminalFor: window)
    }

    @objc private func menuInsertRelativePath(_ sender: NSMenuItem) {
        guard let row = menuRow(sender) else { return }
        FileExplorerTerminalPathInsertion.insert(
            paths: menuResults(forRow: row).map(\.relativePath),
            intoTerminalFor: window
        )
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let row = menuRow(sender) else { return }
        let text = menuResults(forRow: row).map(\.path).joined(separator: "\n")
        GhosttyApp.terminalPasteboard.writeString(text, to: .general)
    }

    @objc private func menuCopyRelativePath(_ sender: NSMenuItem) {
        guard let row = menuRow(sender) else { return }
        let text = menuResults(forRow: row).map(\.relativePath).joined(separator: "\n")
        GhosttyApp.terminalPasteboard.writeString(text, to: .general)
    }

    /// Hides a file's results, like VS Code's Dismiss. The next search
    /// shows it again.
    @objc private func menuDismiss(_ sender: NSMenuItem) {
        guard let row = menuRow(sender), let file = item(atRow: row) as? FileSearchFileNode,
              session.engine.tree.remove(file) else { return }
        reloadRows()
        updateStatus()
    }
}
