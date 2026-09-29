import AppKit

/// The Find mode's results: a flat table of file rows, each followed by its
/// match rows (see `FileSearchRowList`). Rows are fixed height and cells are
/// reused, so AppKit only builds views for visible rows.
final class FileExplorerSearchResultsTableView: NSTableView {
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Weak marker for the view retained by the pasteboard writer until
    /// AppKit reports completion. A strong edge from this table would form
    /// a cycle because that view owns the table.
    weak var activeNativeDragDelegateMarker: AnyObject?
    var activeNativeDragSession: NSDraggingSession?
    weak var pendingNativeDragWriter: FilePreviewDragPasteboardWriter?
    var pendingNativeDragTokenID: UUID?
    // NSDraggingItem owns the writer while AppKit runs the session. A weak
    // edge prevents the writer's retained owner from forming an
    // owner → table → writer cycle when endedAt is delayed.
    weak var activeNativeDragWriter: FilePreviewDragPasteboardWriter?
    var activeNativeDragOwnerships: [FilePreviewNativeDragOwnership] = []
    var activeNativeDragOwnership: FilePreviewNativeDragOwnership? {
        get { activeNativeDragOwnerships.first }
        set { activeNativeDragOwnerships = newValue.map { [$0] } ?? [] }
    }
    /// Called before AppKit evaluates a new pointer gesture. A new
    /// `mouseDown` cannot arrive while the old native drag loop is still live,
    /// so this is the authoritative boundary for a source whose `endedAt`
    /// callback was suppressed during view reconstruction.
    var onNativeDragPointerBoundary: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?
    /// F4 (+1) and Shift-F4 (-1): the next or previous match.
    var onNavigateMatch: ((Int) -> Void)?
    /// Up from the first row returns to the query field.
    var onExitTop: (() -> Void)?
    /// Left/Right (or H/L) on the selected row.
    var onDisclosure: ((RightSidebarKeyboardNavigation.DisclosureAction) -> Void)?
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
        if let delta = FileSearchKeys.matchNavigationDelta(for: event) {
            onNavigateMatch?(delta)
            return
        }
        switch event.keyCode {
        case 36, 76:
            onCommit?()
            return
        case 53:
            onCancel?()
            return
        default:
            break
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            moveSelection(by: delta)
            return
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            onDisclosure?(action)
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self {
            if handleOpenSelectionShortcut(event) { return true }
            if let delta = FileSearchKeys.matchNavigationDelta(for: event) {
                onNavigateMatch?(delta)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Moves the selection one row, handing focus back to the query field
    /// when moving up from the first row.
    func moveSelection(by delta: Int) {
        guard numberOfRows > 0 else { return }
        let current = selectedRow
        if current <= 0, delta < 0 {
            onExitTop?()
            return
        }
        let target = min(max((current < 0 ? -1 : current) + delta, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        scrollRowToVisible(target)
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

/// Keys Find handles itself, in the query field and in the results.
enum FileSearchKeys {
    static let f4KeyCode: UInt16 = 118

    /// +1 for F4, -1 for Shift-F4, as VS Code's next/previous search result.
    static func matchNavigationDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown, event.keyCode == f4KeyCode else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty { return 1 }
        if flags == .shift { return -1 }
        return nil
    }
}
