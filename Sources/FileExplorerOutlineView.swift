import AppKit

enum FileExplorerKeyboardActivation {
    static func isDefaultOpenEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return false
        }
        return event.keyCode == 36 || event.keyCode == 76
    }

    static func matchesOpenSelectionShortcut(
        _ event: NSEvent,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut = KeyboardShortcutSettings.shortcut(for:)
    ) -> Bool {
        isDefaultOpenEvent(event) || matchesConfiguredOpenSelectionShortcut(
            event,
            shortcutForAction: shortcutForAction
        )
    }

    static func matchesConfiguredOpenSelectionShortcut(
        _ event: NSEvent,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut = KeyboardShortcutSettings.shortcut(for:)
    ) -> Bool {
        shortcutForAction(.openFileExplorerSelection).matches(event: event)
    }
}

/// NSOutlineView subclass that disables expand/collapse animations and adds leading margin.
final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    var onQuickSearchChanged: ((String?) -> Void)?
    private var quickSearchActive = false
    private var quickSearchQuery = ""

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            if fileExplorerCoordinator?.handleModeShortcut(mode, in: window) == true {
                return
            }
        }

        if handleOpenSelectionShortcut(event) {
            return
        }

        if quickSearchActive, handleQuickSearchKey(event) {
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return
        }

        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return
        }

        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            beginQuickSearch()
            return
        }

        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleOpenSelectionShortcut(event) {
            return true
        }
        if quickSearchActive, handleQuickSearchKey(event) {
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            endQuickSearch()
            redrawVisibleRows()
        }
        return result
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: expandChildren)
        NSAnimationContext.endGrouping()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingMargin
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let cellShift: CGFloat = Self.leadingMargin - 6
        frame.origin.x += cellShift
        frame.size.width -= cellShift
        return frame
    }

    private func redrawVisibleRows() {
        setNeedsDisplay(bounds)
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, numberOfRows)
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private var fileExplorerCoordinator: FileExplorerPanelView.Coordinator? {
        dataSource as? FileExplorerPanelView.Coordinator
    }

    private func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        let isDefaultOpenEvent = FileExplorerKeyboardActivation.isDefaultOpenEvent(event)
        guard isDefaultOpenEvent || FileExplorerKeyboardActivation.matchesConfiguredOpenSelectionShortcut(event) else {
            return false
        }
        guard isDefaultOpenEvent ||
            (AppDelegate.shared?.shortcutWhenClauseAllows(action: .openFileExplorerSelection, event: event) ?? true) else {
            return false
        }
        endQuickSearch()
        _ = fileExplorerCoordinator?.openSelectedItem(in: self)
        return true
    }

    private func beginQuickSearch() {
        quickSearchActive = true
        quickSearchQuery = ""
        onQuickSearchChanged?(quickSearchQuery)
    }

    private func endQuickSearch() {
        guard quickSearchActive || !quickSearchQuery.isEmpty else { return }
        quickSearchActive = false
        quickSearchQuery = ""
        onQuickSearchChanged?(nil)
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 51 {
            if !quickSearchQuery.isEmpty {
                quickSearchQuery.removeLast()
                onQuickSearchChanged?(quickSearchQuery)
                fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
            }
            return true
        }
        guard RightSidebarKeyboardNavigation.isPlainPrintableText(event) else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return true
        }
        quickSearchQuery += text
        onQuickSearchChanged?(quickSearchQuery)
        fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
        return true
    }
}
