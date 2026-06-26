import AppKit
import CmuxFoundation

// File explorer context menus, split out of FileExplorerView.swift.
//
// Owns the NSMenuDelegate-driven population of the per-row context menus and the
// @objc reveal/copy/open action handlers for two surfaces:
//   - the file outline view (FileExplorerPanelView.Coordinator), and
//   - the search-results table (FileExplorerContainerView).
//
// Menu-item construction shared with other entrypoints lives in
// FileExplorerExternalOpenMenu.swift (external-open items) and
// FileExplorerTerminalPathInsertion.swift (insert-path items + their handlers);
// this file owns only the menu assembly per click and the reveal/copy/open
// actions wired to those items.

extension FileExplorerPanelView.Coordinator {
    // MARK: - Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outlineView else { return }
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let node = outlineView.item(atRow: clickedRow) as? FileExplorerNode else { return }

        let isLocal = store.provider is LocalFileExplorerProvider

        if !node.isDirectory && isLocal {
            menu.addFileExplorerExternalOpenItems(
                fileURL: URL(fileURLWithPath: node.path),
                target: self,
                action: #selector(contextMenuOpenExternally(_:))
            )
        }

        if isLocal {
            let revealItem = NSMenuItem(
                title: FileExternalOpenText().revealInFinder,
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
        FileExternalOpenAction.live.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }

    @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        FileExternalOpenAction.live.revealInFinder(fileURL: URL(fileURLWithPath: node.path))
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

extension FileExplorerContainerView {
    // MARK: - Search Result Context Menu (NSMenuDelegate)

    private func searchResult(forMenuItem sender: NSMenuItem) -> FileSearchResult? {
        guard let row = (sender.representedObject as? NSNumber)?.intValue,
              row >= 0,
              row < searchSnapshot.results.count else {
            return nil
        }
        return searchSnapshot.results[row]
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

        menu.addFileExplorerExternalOpenItems(
            fileURL: URL(fileURLWithPath: searchSnapshot.results[row].path),
            target: self,
            action: #selector(contextMenuOpenSearchResultExternally(_:))
        )

        let revealItem = NSMenuItem(
            title: FileExternalOpenText().revealInFinder,
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

    @objc private func contextMenuOpenSearchResultInCmux(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        coordinator.onOpenFilePreview(result.path)
    }

    @objc private func contextMenuOpenSearchResultExternally(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
        FileExternalOpenAction.live.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }

    @objc private func contextMenuRevealSearchResultInFinder(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        FileExternalOpenAction.live.revealInFinder(fileURL: URL(fileURLWithPath: result.path))
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
