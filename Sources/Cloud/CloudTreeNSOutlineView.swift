import AppKit
import CmuxFoundation

/// The Cloud tab's outline: animation-free disclosure, the right-sidebar
/// keyboard vocabulary (j/k, h/l, arrows, Return opens, `/` quick-search), and
/// the mode shortcuts that jump between sidebar tabs.
final class CloudTreeNSOutlineView: NSOutlineView {
    static let leadingMargin: CGFloat = 8

    /// Keeps the outline delegate/source graph alive while AppKit owns a
    /// native surface drag, including reconstruction between writer creation
    /// and `willBeginAt`.
    var activeNativeDragOwner: AnyObject?
    var activeNativeDragSession: NSDraggingSession?

    /// The active visual preset; the coordinator keeps this in step with the
    /// style it lays rows out with (chevron centering depends on it).
    var treeStyle: CloudTreeStyle = CloudTreeStyleStore.current

    var onOpenSelection: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onDisclosure: ((RightSidebarKeyboardNavigation.DisclosureAction) -> Void)?
    var onQuickSearch: ((String) -> Void)?
    var onDidBecomeFirstResponder: (() -> Void)?
    private var quickSearchQuery: String?

    override func keyDown(with event: NSEvent) {
        if handle(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return true
        }
        if quickSearchQuery != nil, handleQuickSearchKey(event) {
            return true
        }
        // Return / keypad Enter opens the selection; Escape clears it.
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelection?()
            return true
        }
        if event.keyCode == 53 {
            deselectAll(nil)
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            quickSearchQuery = nil
            onMoveSelection?(delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            quickSearchQuery = nil
            onDisclosure?(action)
            return true
        }
        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            quickSearchQuery = ""
            return true
        }
        return false
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        guard var query = quickSearchQuery else { return false }
        switch event.keyCode {
        case 53, 36, 76:
            quickSearchQuery = nil
            return event.keyCode == 53
        case 51:
            if !query.isEmpty {
                query.removeLast()
                quickSearchQuery = query
                onQuickSearch?(query)
            }
            return true
        default:
            guard RightSidebarKeyboardNavigation.isPlainPrintableText(event),
                  let text = event.charactersIgnoringModifiers, !text.isEmpty else {
                return false
            }
            query += text
            quickSearchQuery = query
            onQuickSearch?(query)
            return true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onDidBecomeFirstResponder?()
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            quickSearchQuery = nil
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

    /// How far `frameOfCell` moves content past AppKit's default; the cell adds the
    /// rest of `CloudTreeRowGrid.disclosureGap` so every row's content starts 6pt
    /// after the 16pt disclosure slot (`indentationPerLevel`).
    static let cellShift: CGFloat = leadingMargin - 6

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingMargin
        if treeStyle.machineRowLayout == .twoLine,
           let node = item(atRow: row) as? CloudTreeNode, node.isMachineRow {
            // Multi-line machine rows: the chevron centers on the name line (first
            // line, after the row's top padding), not on the row's vertical middle,
            // so it reads with the name and the status dot. NSTableView is flipped.
            let rowFrame = rect(ofRow: row)
            let nameLineCenter = rowFrame.minY
                + GlobalFontMagnification.scaledSize(treeStyle.machineVerticalPadding)
                + GlobalFontMagnification.scaledSize(treeStyle.machineNameLineHeight) / 2
            frame.origin.y = (nameLineCenter - frame.height / 2).rounded()
        }
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let cellShift = Self.cellShift
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
}
