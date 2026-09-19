import AppKit
import CmuxFoundation

/// The Cloud tab's outline: animation-free disclosure, the right-sidebar
/// keyboard vocabulary (j/k, h/l, arrows, Return opens, `/` quick-search), and
/// the mode shortcuts that jump between sidebar tabs.
final class CloudTreeNSOutlineView: NSOutlineView {
    static let leadingMargin: CGFloat = 8
    lazy var reorderPresentation = CloudTreeReorderPresentation(outline: self)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        draggingDestinationFeedbackStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let native = super.makeView(withIdentifier: identifier, owner: owner)
        guard identifier == NSOutlineView.disclosureButtonIdentifier,
              let button = native as? NSButton else { return native }
        return (button as? CloudTreeDisclosureButton) ?? CloudTreeDisclosureButton(nativeButton: button)
    }

    private var hoverTrackingArea: NSTrackingArea?
    private weak var hoveredCell: CloudTreeCellView?

    /// The outline owns exactly one hover target. Cells cannot retain independent
    /// enter/exit state across tracking-area replacement, scrolling, or reloads.
    private func updateHover(at point: NSPoint?) {
        var next: CloudTreeCellView?
        if let point, visibleRect.contains(point) {
            let row = row(at: point)
            if row >= 0,
               let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? CloudTreeCellView,
               convert(cell.bounds, from: cell).contains(point) {
                next = cell
            }
        }
        if hoveredCell !== next {
            hoveredCell?.setHovered(false)
            hoveredCell = next
        }
        next?.setHovered(true)
    }

    private func refreshHover() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else {
            updateHover(at: nil)
            return
        }
        let pointerInWindow = window.convertFromScreen(
            NSRect(origin: window.mouseLocationOutsideOfEventStream, size: .zero)
        ).origin
        updateHover(at: convert(pointerInWindow, from: nil))
    }

    @objc private func hoverEnvironmentDidChange(_ notification: Notification) {
        refreshHover()
        reorderPresentation.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // Tracking-area replacement can deliver a stale exit after the new
        // area has refreshed; recompute from the current pointer location.
        refreshHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { reorderPresentation.clear() }
        updateHover(at: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(hoverEnvironmentDidChange(_:)),
                name: NSWindow.didResignKeyNotification, object: newWindow
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(hoverEnvironmentDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification, object: newWindow
            )
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(hoverEnvironmentDidChange(_:)),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
        updateHover(at: nil)
    }

    override func layout() {
        super.layout()
        reorderPresentation.layout()
        refreshHover()
    }

    var activeNativeDragCoordinator: AnyObject?
    var activeNativeDragSession: NSDraggingSession? {
        didSet { if activeNativeDragSession == nil { reorderPresentation.clear() } }
    }
    var onNativeDragPointerBoundary: (() -> Void)?
    var onDocumentContentChanged: (() -> Void)?

    var treeStyle: CloudTreeStyle = CloudTreeStyleStore.current

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        let selectable = IndexSet(indexes.filter { row in
            (item(atRow: row) as? CloudTreeNode)?.kind.isSelectable == true
        })
        guard indexes.isEmpty || !selectable.isEmpty else { return }
        super.selectRowIndexes(selectable, byExtendingSelection: extend)
    }

    /// Per-event context menu, the same presentation path the sidebar rows
    /// use. The persistent `menu` + delegate `menuNeedsUpdate` route rendered
    /// items whose actions never dispatched; building the menu in
    /// `menu(for:)` is the pattern proven by every working cmux menu.
    var contextMenuBuilder: ((_ row: Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenuBuilder else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuBuilder(row)
    }

    var onOpenSelection: (() -> Void)?
    let ownershipFeedback = SurfaceDropFeedback()
    var onMoveSelection: ((Int) -> Void)?
    var onDisclosure: ((RightSidebarKeyboardNavigation.DisclosureAction) -> Void)?
    var onQuickSearch: ((String) -> Void)?
    var onDidBecomeFirstResponder: (() -> Void)?
    private var quickSearchQuery: String?

    override func mouseDown(with event: NSEvent) {
        reorderPresentation.clear()
        onNativeDragPointerBoundary?()
        super.mouseDown(with: event)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        ownershipFeedback.clear()
        guard reorderPresentation.isCurrent(sender) else { return }
        super.draggingExited(sender)
        reorderPresentation.clear(sequence: sender?.draggingSequenceNumber)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        ownershipFeedback.clear()
        guard reorderPresentation.isCurrent(sender) else { return }
        super.draggingEnded(sender)
        reorderPresentation.ended(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        ownershipFeedback.clear()
        guard reorderPresentation.isCurrent(sender) else { return }
        super.concludeDragOperation(sender)
        reorderPresentation.clear(sequence: sender?.draggingSequenceNumber)
    }

    override func viewDidHide() {
        ownershipFeedback.clear()
        super.viewDidHide()
        reorderPresentation.clear()
    }

    override func keyDown(with event: NSEvent) {
        if handle(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Native row controls own their keys; Return must not also toggle the group.
        if let control = window?.firstResponder as? NSControl,
           control !== self, control.isDescendant(of: self) { return false }
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
        onDocumentContentChanged?()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
        onDocumentContentChanged?()
    }

    override func reloadData() {
        reorderPresentation.clear()
        updateHover(at: nil)
        super.reloadData()
        needsLayout = true
        onDocumentContentChanged?()
    }
    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        updateHover(at: nil)
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        needsLayout = true
        onDocumentContentChanged?()
    }

    private func disclosureLeading(atRow row: Int) -> CGFloat {
        GlobalFontMagnification.scaledSize(
            Self.leadingMargin + CGFloat(max(0, level(forRow: row))) * treeStyle.indentPerLevel
        )
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x = disclosureLeading(atRow: row)
        frame.size = NSSize(width: GlobalFontMagnification.scaledSize(CloudTreeRowGrid.disclosureSlot),
                            height: GlobalFontMagnification.scaledSize(CloudTreeRowGrid.disclosureSlot))
        if let node = item(atRow: row) as? CloudTreeNode, node.isMachineRow,
           treeStyle.machineRowLayout == .twoLine {
            // Multi-line machine rows: the chevron centers on the name line (first
            // line, after the row's top padding), not on the row's vertical middle,
            // so it reads with the name and the status dot. NSTableView is flipped.
            let rowFrame = rect(ofRow: row)
            let nameLineCenter = rowFrame.minY
                + GlobalFontMagnification.scaledSize(treeStyle.machineVerticalPadding + treeStyle.machineBandVerticalPadding)
                + GlobalFontMagnification.scaledSize(treeStyle.machineNameLineHeight) / 2
            frame.origin.y = (nameLineCenter - frame.height / 2).rounded()
        } else {
            frame.origin.y = (rect(ofRow: row).midY - frame.height / 2).rounded()
        }
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let trailing = frame.maxX
        frame.origin.x = disclosureLeading(atRow: row) + GlobalFontMagnification.scaledSize(
            CloudTreeRowGrid.disclosureSlot + CloudTreeRowGrid.disclosureGap
        )
        frame.size.width = max(0, trailing - frame.minX)
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
