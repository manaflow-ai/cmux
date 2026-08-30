import AppKit

final class FileExplorerSearchResultsTableView: NSTableView {
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Weak marker for the container retained by the pasteboard writer until
    /// AppKit reports completion. A strong table → container edge would form a
    /// cycle because the container owns this table.
    weak var activeNativeDragDelegateMarker: AnyObject?
    var activeNativeDragSession: NSDraggingSession?
    weak var pendingNativeDragWriter: FilePreviewDragPasteboardWriter?
    var activeNativeDragOwnership: FilePreviewNativeDragOwnership?
    /// Called before AppKit evaluates a new pointer gesture. A new
    /// `mouseDown` cannot arrive while the old native drag loop is still live,
    /// so this is the authoritative boundary for a source whose `endedAt`
    /// callback was suppressed during view reconstruction.
    var onNativeDragPointerBoundary: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?
    var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        onNativeDragPointerBoundary?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
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

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            if onModeShortcut?(mode, window) == true {
                return
            }
        }
        if handleOpenSelectionShortcut(event) { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleOpenSelectionShortcut(event) { return true }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
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
}
