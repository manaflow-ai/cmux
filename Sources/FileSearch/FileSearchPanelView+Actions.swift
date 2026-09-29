import AppKit
import CmuxFileSearch
import CmuxSettings
import CmuxWorkspaces

// Keyboard, focus and open actions.
extension FileSearchPanelView: NSSearchFieldDelegate {
    // MARK: - Query field

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === queryBar.queryField else { return }
        historyCursor.reset()
        queryDidChange(immediate: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === queryBar.queryField, !textView.hasMarkedText() else { return false }
        if let event = NSApp.currentEvent {
            if queryBar.queryField.handleOpenSelectionShortcut(event) { return true }
            if queryBar.queryField.handleMatchNavigation(event) { return true }
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitFromQueryField()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        case #selector(NSResponder.moveUp(_:)):
            showPreviousHistoryEntry()
            return true
        case #selector(NSResponder.moveDown(_:)):
            if historyCursor.isBrowsing {
                showNextHistoryEntry()
            } else {
                focusResults(selectingFirstIfNeeded: true)
            }
            return true
        default:
            return false
        }
    }

    private func showPreviousHistoryEntry() {
        guard let entry = historyCursor.previous(in: history, current: queryBar.queryField.stringValue) else { return }
        showHistoryEntry(entry)
    }

    private func showNextHistoryEntry() {
        guard let entry = historyCursor.next(in: history) else { return }
        showHistoryEntry(entry)
    }

    private func showHistoryEntry(_ entry: String) {
        queryBar.queryField.stringValue = entry
        if let editor = queryBar.queryField.currentEditor() {
            editor.selectedRange = NSRange(location: (entry as NSString).length, length: 0)
        }
        queryDidChange(immediate: false)
    }

    /// Return in the query field opens the selected result. When the typed
    /// query has not been searched yet, it searches now instead.
    func commitFromQueryField() {
        let request = session.engine.activeRequest
        let isSearched = request.map { $0.query == session.query && $0.rootPath == rootPath } ?? false
        if !isSearched || session.engine.tree.isEmpty {
            recordHistory()
            runSearchNow()
            return
        }
        openSelectedResult()
    }

    /// Escape clears a non-empty query and keeps focus in the field; with
    /// nothing to clear it leaves Find.
    func handleEscape() {
        if !session.query.pattern.isEmpty {
            clearSearch()
            _ = focusQueryField(seed: nil)
            return
        }
        onDismiss?()
    }

    // MARK: - Focus

    /// Focuses the query field. A non-empty `seed` (the selection the user
    /// invoked Find with) replaces the query and searches at once.
    @discardableResult
    func focusQueryField(seed: String?) -> Bool {
        guard let window else { return false }
        if let seed, !seed.isEmpty, seed != queryBar.queryField.stringValue {
            queryBar.queryField.stringValue = seed
            historyCursor.reset()
            session.query = queryBar.query
            runSearchNow()
        }
        let result = window.makeFirstResponder(queryBar.queryField)
        queryBar.queryField.selectText(nil)
        return result
    }

    func focusResults(selectingFirstIfNeeded: Bool) {
        guard resultsView.numberOfRows > 0, let window else { return }
        if resultsView.selectedRow < 0, selectingFirstIfNeeded {
            resultsView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        resultsView.scrollRowToVisible(max(resultsView.selectedRow, 0))
        window.makeFirstResponder(resultsView)
    }

    // MARK: - Selection and navigation

    func select(item: Any, scroll: Bool) {
        if let node = item as? FileSearchMatchNode, !resultsView.isItemExpanded(node.file) {
            node.file.isExpanded = true
            resultsView.expandItem(node.file)
        }
        let row = resultsView.row(forItem: item)
        guard row >= 0 else { return }
        resultsView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll { resultsView.scrollRowToVisible(row) }
    }

    /// F4 / Shift-F4: select the next or previous match and open it.
    func navigateMatch(by delta: Int) {
        let tree = session.engine.tree
        let current = resultsView.selectedRow >= 0 ? resultsView.item(atRow: resultsView.selectedRow) : nil
        let position: FileSearchResultPosition?
        if let node = current as? FileSearchMatchNode {
            position = tree.position(of: node)
        } else if let file = current as? FileSearchFileNode, let index = tree.index(of: file) {
            position = FileSearchResultPosition(fileIndex: index, matchIndex: nil)
        } else {
            position = nil
        }
        let target = delta >= 0 ? tree.nextMatch(after: position) : tree.previousMatch(before: position)
        guard let target, let matchIndex = target.matchIndex else { return }
        let node = tree.files[target.fileIndex].matchNode(at: matchIndex)
        select(item: node, scroll: true)
        openKeepingFocus(file: node.file, match: node.match)
    }

    /// F4 keeps keyboard focus in Find so it can be pressed again, as in
    /// VS Code: a local file shows in its (reused) preview without taking
    /// focus. Anything else opens through the normal path.
    private func openKeepingFocus(file: FileSearchFileNode, match: FileSearchMatch) {
        let hasPreferredEditor = PreferredEditorSettingsStore(defaults: .standard).resolvedCommand != nil
        let activation = FileExplorerDoubleClickActionSettings.fileActivation(
            action: FileExplorerDoubleClickActionSettings.resolvedAction(),
            hasPreferredEditorCommand: hasPreferredEditor
        )
        guard case .preview = activation,
              coordinator.store.provider is LocalFileExplorerProvider,
              resourceContextID == coordinator.store.resourceContextID,
              let window,
              let workspaceID = coordinator.store.workspaceRootIdentity,
              let workspace = AppDelegate.shared?.contextForMainTerminalWindow(window)?
                .tabManager.tabs.first(where: { $0.id == workspaceID }),
              !workspace.usesRemoteDirectoryProvenance,
              let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            open(file: file, match: match)
            return
        }
        recordHistory()
        FilePreviewRevealCenter.shared.request(
            FilePreviewRevealLocation(line: match.lineNumber, column: match.column, length: match.length),
            forPath: file.path
        )
        _ = workspace.openFileSurfaces(inPane: pane, filePaths: [file.path], focus: false, reuseExisting: true)
    }

    // MARK: - Opening

    @objc func openClickedResult(_ sender: Any?) {
        let row = resultsView.clickedRow >= 0 ? resultsView.clickedRow : resultsView.selectedRow
        guard row >= 0, let item = resultsView.item(atRow: row) else { return }
        if let file = item as? FileSearchFileNode, resultsView.clickedRow >= 0 {
            // Double-clicking a file row toggles it, like the Files tree.
            if resultsView.isItemExpanded(file) {
                file.isExpanded = false
                resultsView.collapseItem(file)
            } else {
                file.isExpanded = true
                resultsView.expandItem(file)
            }
            return
        }
        openResult(item)
    }

    func openSelectedResult() {
        let row = resultsView.selectedRow
        guard row >= 0, let item = resultsView.item(atRow: row) else { return }
        openResult(item)
    }

    func openResult(_ item: Any) {
        if let node = item as? FileSearchMatchNode {
            open(file: node.file, match: node.match)
        } else if let file = item as? FileSearchFileNode {
            open(file: file, match: file.matches.first)
        }
    }

    /// Opens a result at its line and column through the configured
    /// file-open action. Remote files open in the cmux preview.
    func open(file: FileSearchFileNode, match: FileSearchMatch?) {
        guard resourceContextID == coordinator.store.resourceContextID else { return }
        recordHistory()
        let path = file.path
        let location = match.map {
            FilePreviewRevealLocation(line: $0.lineNumber, column: $0.column, length: $0.length)
        }
        guard coordinator.store.provider is LocalFileExplorerProvider else {
            if let location { FilePreviewRevealCenter.shared.request(location, forPath: path) }
            coordinator.onOpenFilePreview(path)
            return
        }
        let action = FileExplorerDoubleClickActionSettings.resolvedAction()
        let hasPreferredEditor = PreferredEditorSettingsStore(defaults: .standard).resolvedCommand != nil
        switch FileExplorerDoubleClickActionSettings.fileActivation(
            action: action,
            hasPreferredEditorCommand: hasPreferredEditor
        ) {
        case .preview:
            if let location { FilePreviewRevealCenter.shared.request(location, forPath: path) }
            coordinator.onOpenFilePreview(path)
        case .defaultEditor:
            FileExternalOpenAction.openDefault(fileURL: URL(fileURLWithPath: path))
        case .preferredEditor:
            PreferredEditorService(defaults: .standard).open(
                URL(fileURLWithPath: path),
                line: match?.lineNumber,
                column: match?.column
            )
        }
    }
}
