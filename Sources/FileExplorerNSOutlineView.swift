import AppKit
import Quartz

/// NSOutlineView subclass for the Files tree: no expand/collapse animation,
/// leading margin, Finder keyboard behavior (type-select, Option-arrow
/// recursive disclosure, Space for Quick Look) and Edit menu copy/paste.
final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Weak marker for the delegate retained by the pasteboard writer while
    /// AppKit owns a native preview drag. Keeping this marker weak avoids a
    /// table → container → table cycle during a SwiftUI teardown.
    weak var activeNativeDragDelegateMarker: AnyObject?
    var activeNativeDragSession: NSDraggingSession?
    weak var pendingNativeDragWriter: FilePreviewDragPasteboardWriter?
    var pendingNativeDragTokenID: UUID?
    // NSDraggingItem retains the writer for the native session. Keeping this
    // edge weak avoids a view → writer → container cycle during reconstruction;
    // the immutable ownership record below carries terminal cleanup identity.
    weak var activeNativeDragWriter: FilePreviewDragPasteboardWriter?
    var activeNativeDragOwnerships: [FilePreviewNativeDragOwnership] = []
    var activeNativeDragOwnership: FilePreviewNativeDragOwnership? {
        get { activeNativeDragOwnerships.first }
        set { activeNativeDragOwnerships = newValue.map { [$0] } ?? [] }
    }
    /// Called before a new pointer gesture so a lost native terminal callback
    /// cannot leave this outline's source graph latched forever.
    var onNativeDragPointerBoundary: (() -> Void)?
    var onQuickSearchChanged: ((String?) -> Void)?
    /// True while this outline's context menu is on screen. AppKit keeps
    /// drawing the context-menu highlight for the clicked row until the menu
    /// closes, and throws if a reload leaves that row outside the row data
    /// (#12914), so row reloads wait for `onContextMenuDidClose`.
    private(set) var isContextMenuOpen = false
    var onContextMenuDidClose: (() -> Void)?
    private var quickSearchActive = false
    private var quickSearchQuery = ""
    /// Finder type-select buffer; it resets after a pause between keys.
    private var typeSelectBuffer = ""
    private var typeSelectLastTimestamp: TimeInterval = 0
    private static let typeSelectResetInterval: TimeInterval = 1.0
    /// True while AppKit collapses an item together with its descendants.
    private(set) var isCollapsingChildren = false

    override func mouseDown(with event: NSEvent) {
        onNativeDragPointerBoundary?()
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if !isContextMenuOpen {
            fileExplorerCoordinator?.contextMenuDidOpen()
        }
        isContextMenuOpen = true
        super.willOpenMenu(menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        isContextMenuOpen = false
        onContextMenuDidClose?()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            if fileExplorerCoordinator?.handleModeShortcut(mode, in: window) == true {
                return
            }
        }

        if quickSearchActive,
           RightSidebarKeyboardNavigation.isPlainPrintableText(event),
           handleQuickSearchKey(event) {
            return
        }

        if handleTypeSelectContinuation(event) {
            return
        }

        if handleOpenSelectionShortcut(event) || handleFinderActionShortcut(event) {
            return
        }

        if quickSearchActive, handleQuickSearchKey(event) {
            return
        }

        if handleRecursiveDisclosure(event) || handleExtendSelection(event) {
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

        if handleTypeSelectStart(event) {
            return
        }

        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if quickSearchActive,
           RightSidebarKeyboardNavigation.isPlainPrintableText(event),
           handleQuickSearchKey(event) {
            return true
        }
        if handleOpenSelectionShortcut(event) || handleFinderActionShortcut(event) {
            return true
        }
        if quickSearchActive, handleQuickSearchKey(event) {
            return true
        }
        if handleRecursiveDisclosure(event) {
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

    // MARK: - Finder keyboard behavior

    /// Option-Right and Option-Left expand or collapse the selection recursively.
    private func handleRecursiveDisclosure(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard flags == .option, event.keyCode == 123 || event.keyCode == 124 else { return false }
        endQuickSearch()
        fileExplorerCoordinator?.performRecursiveDisclosure(expand: event.keyCode == 124, in: self)
        return true
    }

    /// Shift-Up and Shift-Down extend the selection like any AppKit list.
    private func handleExtendSelection(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard flags == .shift, event.keyCode == 125 || event.keyCode == 126 else { return false }
        endQuickSearch()
        super.keyDown(with: event)
        return true
    }

    /// Continues a type-select burst: once it started, every printable key
    /// (including Space and the Vim letters) extends the name being typed.
    private func handleTypeSelectContinuation(_ event: NSEvent) -> Bool {
        guard !typeSelectBuffer.isEmpty, !quickSearchActive,
              RightSidebarKeyboardNavigation.isPlainPrintableText(event),
              event.timestamp - typeSelectLastTimestamp < Self.typeSelectResetInterval,
              let text = event.characters, !text.isEmpty else {
            if event.timestamp - typeSelectLastTimestamp >= Self.typeSelectResetInterval {
                typeSelectBuffer = ""
            }
            return false
        }
        typeSelectBuffer += text
        typeSelectLastTimestamp = event.timestamp
        fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: typeSelectBuffer)
        return true
    }

    /// Starts type-select on a printable key that is not a navigation key.
    /// `h`, `j`, `k`, `l` and `/` keep their Vim and quick-search meaning.
    private func handleTypeSelectStart(_ event: NSEvent) -> Bool {
        guard !quickSearchActive, RightSidebarKeyboardNavigation.isPlainPrintableText(event),
              let text = event.characters, !text.isEmpty, text != " " else { return false }
        typeSelectBuffer = text
        typeSelectLastTimestamp = event.timestamp
        fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: text)
        return true
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        if fileExplorerCoordinator?.copySelection(in: self) != true { NSSound.beep() }
    }

    @objc func paste(_ sender: Any?) {
        if fileExplorerCoordinator?.pasteFiles(in: self) != true { NSSound.beep() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return numberOfSelectedRows > 0
        case #selector(paste(_:)):
            return fileExplorerCoordinator?.store.supportsFileOperations == true &&
                NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard !quickLookURLs.isEmpty else {
                NSSound.beep()
                return
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Keeps an open Quick Look panel on the current selection.
    func selectionDidChangeForQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return }
        panel.reloadData()
    }

    private var quickLookURLs: [URL] {
        guard fileExplorerCoordinator?.store.provider is LocalFileExplorerProvider else { return [] }
        return selectedRowIndexes.compactMap { item(atRow: $0) as? FileExplorerNode }
            .map { URL(fileURLWithPath: $0.path) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !quickLookURLs.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
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
        // Option-clicking a disclosure triangle asks AppKit to expand every
        // descendant, but lazily listed folders have none yet. The store
        // expands them as their listings arrive, within a folder budget.
        if expandChildren, let node = item as? FileExplorerNode {
            fileExplorerCoordinator?.store.expandRecursively(node: node)
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: false)
        NSAnimationContext.endGrouping()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        let wasCollapsingChildren = isCollapsingChildren
        isCollapsingChildren = collapseChildren
        defer { isCollapsingChildren = wasCollapsingChildren }
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

    private func beginQuickSearch() {
        quickSearchActive = true
        quickSearchQuery = ""
        onQuickSearchChanged?(quickSearchQuery)
    }

    func endQuickSearch() {
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
        if event.keyCode == 125 || event.keyCode == 126 {
            // Down/Up step through matches without leaving quick search.
            fileExplorerCoordinator?.selectNextQuickSearchMatch(
                in: self, query: quickSearchQuery, forward: event.keyCode == 125
            )
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

extension FileExplorerNSOutlineView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = quickLookURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the tree selection, like Finder.
        guard let event, event.type == .keyDown,
              event.keyCode == 125 || event.keyCode == 126 else { return false }
        fileExplorerCoordinator?.moveSelection(in: self, by: event.keyCode == 125 ? 1 : -1)
        return true
    }
}
