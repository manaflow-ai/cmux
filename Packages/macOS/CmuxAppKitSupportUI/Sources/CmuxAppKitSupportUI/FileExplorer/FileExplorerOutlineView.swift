public import AppKit
public import CmuxSidebar

/// `NSOutlineView` subclass backing the file-explorer tree, disabling
/// expand/collapse animations, adding a leading margin to the disclosure
/// triangle and cells, and routing key/focus events to the owner through
/// closures rather than reaching into app state.
///
/// The view is closure-driven: focus changes redraw visible rows, the
/// right-sidebar move keys call ``onMoveSelection``, disclosure keys call
/// ``onDisclosureAction``, the quick-search type-to-select query changes call
/// ``onQuickSearchChanged`` and ``onQuickSearchMatch``, and a resolved
/// right-sidebar mode shortcut is offered to ``onModeShortcut``. The mode
/// shortcut is decoded by ``resolveModeShortcut``, which the app injects to keep
/// the AppKit event-to-mode mapping (formerly read from the AppDelegate
/// singleton) out of the package.
public final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    /// Where this outline view is hosted; used by app-side shortcut routing.
    public var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Called when the app-side open-selection shortcut should activate the current row.
    public var onOpenSelection: (() -> Void)?
    /// Called with the active quick-search query string, or `nil` when
    /// quick-search ends.
    public var onQuickSearchChanged: ((String?) -> Void)?
    /// Called with a signed row delta for the right-sidebar move keys.
    public var onMoveSelection: ((Int) -> Void)?
    /// Called with the resolved right-sidebar disclosure action (expand/collapse).
    public var onDisclosureAction: ((RightSidebarDisclosureAction) -> Void)?
    /// Called with the current quick-search query so the owner can select the
    /// best matching row.
    public var onQuickSearchMatch: ((String) -> Void)?
    /// Offered a resolved right-sidebar mode and the current window; returns
    /// `true` when the mode shortcut was handled.
    public var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)?
    /// Decodes a key event into a right-sidebar mode, injected by the app so the
    /// package does not depend on app-side shortcut state.
    public var resolveModeShortcut: ((NSEvent) -> RightSidebarMode?)?
    private var quickSearchActive = false
    private var quickSearchQuery = ""

    override public func keyDown(with event: NSEvent) {
        if let mode = resolveModeShortcut?(event) {
            if onModeShortcut?(mode, window) == true {
                return
            }
        }

        if quickSearchActive, handleQuickSearchKey(event) {
            return
        }

        if let delta = event.rightSidebarMoveDelta {
            endQuickSearch()
            onMoveSelection?(delta)
            return
        }

        if let action = event.rightSidebarDisclosureAction {
            endQuickSearch()
            onDisclosureAction?(action)
            return
        }

        if event.isPlainRightSidebarSlash {
            beginQuickSearch()
            return
        }

        if event.isPlainRightSidebarPrintableText {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if quickSearchActive, handleQuickSearchKey(event) {
            return true
        }
        if let delta = event.rightSidebarMoveDelta {
            endQuickSearch()
            onMoveSelection?(delta)
            return true
        }
        if let action = event.rightSidebarDisclosureAction {
            endQuickSearch()
            onDisclosureAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            endQuickSearch()
            redrawVisibleRows()
        }
        return result
    }

    override public func expandItem(_ item: Any?, expandChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: expandChildren)
        NSAnimationContext.endGrouping()
    }

    override public func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
    }

    override public func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingMargin
        return frame
    }

    override public func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
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
                onQuickSearchMatch?(quickSearchQuery)
            }
            return true
        }
        guard event.isPlainRightSidebarPrintableText else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return true
        }
        quickSearchQuery += text
        onQuickSearchChanged?(quickSearchQuery)
        onQuickSearchMatch?(quickSearchQuery)
        return true
    }
}
