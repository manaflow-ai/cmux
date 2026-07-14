import AppKit

extension FileExplorerContainerView: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func moveSearchSelection(by delta: Int, focusResults: Bool) {
        guard !searchSnapshot.results.isEmpty else { return }
        let currentRow = searchResultsView.selectedRow >= 0
            ? searchResultsView.selectedRow
            : (delta >= 0 ? -1 : searchSnapshot.results.count)
        let targetRow = min(max(currentRow + delta, 0), searchSnapshot.results.count - 1)
        searchResultsView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        searchResultsView.scrollRowToVisible(targetRow)
        if focusResults, let window { _ = window.makeFirstResponder(searchResultsView) }
    }

    @MainActor
    func openSelectedSearchResult() {
        let row = searchResultsView.selectedRow
        guard row >= 0, row < searchSnapshot.results.count else { return }
        let path = searchSnapshot.results[row].path
        guard coordinator.store.provider is LocalFileExplorerProvider else {
            coordinator.onOpenFilePreview(path)
            return
        }
        performFileExplorerFileOpen(path: path, onOpenFilePreview: coordinator.onOpenFilePreview)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField else { return }
        searchFieldTextDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        if let event = NSApp.currentEvent, searchField.handleOpenSelectionShortcut(event) { return true }
        return handleSearchFieldCommand(commandSelector, textView: textView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { searchSnapshot.results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < searchSnapshot.results.count else { return nil }
        let result = searchSnapshot.results[row]
        let startsFileGroup = row == 0 || searchSnapshot.results[row - 1].path != result.path
        let identifier = NSUserInterfaceItemIdentifier("FileSearchResultCell")
        let cellView = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerSearchResultCellView
            ?? FileExplorerSearchResultCellView(identifier: identifier)
        cellView.configure(with: result, startsFileGroup: startsFileGroup)
        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === searchResultsView, row >= 0, row < searchSnapshot.results.count else {
            return FileExplorerSearchResultCellView.preferredRowHeight
        }
        let startsFileGroup = row == 0 || searchSnapshot.results[row - 1].path != searchSnapshot.results[row].path
        return FileExplorerSearchResultCellView.preferredRowHeight(startsFileGroup: startsFileGroup)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === searchResultsView, row >= 0, row < searchSnapshot.results.count else { return nil }
        let result = searchSnapshot.results[row]
        return FilePreviewDragPasteboardWriter(
            filePath: result.path,
            displayTitle: (result.relativePath as NSString).lastPathComponent
        )
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard tableView === searchResultsView else { return }
        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: NSPasteboard(name: .drag))
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
        let menuSelection = FileExplorerSearchMenuSelection(
            clickedResult: searchSnapshot.results[row],
            selectedResults: searchResultsView.selectedRowIndexes.compactMap {
                searchSnapshot.results.indices.contains($0) ? searchSnapshot.results[$0] : nil
            }
        )

        let openInCmuxItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in cmux"),
            action: #selector(contextMenuOpenSearchResultInCmux(_:)),
            keyEquivalent: ""
        )
        openInCmuxItem.target = self
        openInCmuxItem.representedObject = menuSelection
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
        revealItem.representedObject = menuSelection
        menu.addItem(revealItem)
        menu.addItem(.separator())
        menu.addFileExplorerInsertPathItems(
            target: self,
            representedObject: menuSelection,
            insertAction: #selector(contextMenuInsertSearchResultPath(_:)),
            insertRelativeAction: #selector(contextMenuInsertSearchResultRelativePath(_:))
        )

        for (title, action) in [
            (String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"), #selector(contextMenuCopySearchResultPath(_:))),
            (String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"), #selector(contextMenuCopySearchResultRelativePath(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = menuSelection
            menu.addItem(item)
        }
    }

    func scrollSearchFieldEditorToInsertionPoint() {
        guard let editor = searchField.currentEditor() else { return }
        let selection = editor.selectedRange
        let textLength = (editor.string as NSString).length
        editor.scrollRangeToVisible(NSRange(location: min(selection.location + selection.length, textLength), length: 0))
    }

    private func searchResult(forMenuItem sender: NSMenuItem) -> FileSearchResult? {
        (sender.representedObject as? FileExplorerSearchMenuSelection)?.clickedResult
    }

    @objc func openSelectedSearchResultFromTable(_ sender: NSTableView) {
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.path, forType: .string)
    }

    @objc private func contextMenuCopySearchResultRelativePath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.relativePath, forType: .string)
    }
}
