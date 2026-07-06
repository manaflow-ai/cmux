public import AppKit
public import CmuxSidebar

/// Table view backing the file-explorer search results list, routing key and
/// focus events to the owner through closures rather than reaching into app
/// state.
///
/// The view is entirely closure-driven: focus changes call ``onFocus`` and
/// redraw visible rows, Escape calls ``onCancel``, the right-sidebar move keys
/// call ``onMoveSelection``, Return/Enter calls ``onCommit``, and a resolved
/// right-sidebar mode shortcut is offered to ``onModeShortcut``. The mode
/// shortcut is decoded by ``resolveModeShortcut``, which the app injects to
/// keep the AppKit event-to-mode mapping (formerly read from the AppDelegate
/// singleton) out of the package.
public final class FileExplorerSearchResultsTableView: NSTableView {
    /// Where this search-results view is hosted; used by app-side shortcut routing.
    public var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Called when the Escape key is pressed.
    public var onCancel: (() -> Void)?
    /// Called with a signed row delta for the right-sidebar move keys.
    public var onMoveSelection: ((Int) -> Void)?
    /// Called when Return or Enter commits the current selection.
    public var onCommit: (() -> Void)?
    /// Called when the table becomes first responder.
    public var onFocus: (() -> Void)?
    /// Offered a resolved right-sidebar mode and the current window; returns
    /// `true` when the mode shortcut was handled.
    public var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)?
    /// Decodes a key event into a right-sidebar mode, injected by the app so the
    /// package does not depend on app-side shortcut state.
    public var resolveModeShortcut: ((NSEvent) -> RightSidebarMode?)?

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
            redrawVisibleRows()
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override public func keyDown(with event: NSEvent) {
        if let mode = resolveModeShortcut?(event) {
            if onModeShortcut?(mode, window) == true {
                return
            }
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = event.rightSidebarMoveDelta {
            onMoveSelection?(delta)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        if event.isPlainRightSidebarPrintableText {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let delta = event.rightSidebarMoveDelta {
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
