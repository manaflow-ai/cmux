import AppKit

/// NSOutlineView subclass that disables expand/collapse animations and adds leading margin.
final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    var onFilterRequested: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            if fileExplorerCoordinator?.handleModeShortcut(mode, in: window) == true {
                return
            }
        }

        if handleOpenSelectionShortcut(event) {
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return
        }

        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return
        }

        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            onFilterRequested?()
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
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return true
        }
        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            onFilterRequested?()
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

    var fileExplorerCoordinator: FileExplorerPanelView.Coordinator? {
        dataSource as? FileExplorerPanelView.Coordinator
    }
}
