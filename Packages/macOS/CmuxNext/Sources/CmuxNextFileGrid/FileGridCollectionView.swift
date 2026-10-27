import AppKit
import Carbon.HIToolbox
import Quartz

/// The grid's collection view: turns keys, double clicks and right clicks
/// into ``FileGridCommand`` values for ``FileGridView``, runs clicks, Cmd-A
/// and Esc through ``FileGridSelection`` (Cmd-click toggles, Shift-click
/// selects a run), and drives the Quick Look panel over the selection
/// (Space, as in Finder).
final class FileGridCollectionView: NSCollectionView {
    /// The selection now, with its anchor (``FileGridView`` keeps the anchor by file).
    var currentSelection: () -> FileGridSelection = { FileGridSelection() }
    /// Shows a selection (``FileGridView`` sets it). Nil leaves clicks to AppKit.
    var applySelection: ((FileGridSelection) -> Void)?
    /// Set when a drag of tiles began during the current click (the delegate reports it).
    var dragBegan = false
    /// Whether a press on a tile runs AppKit's own tracking (drag out, release). Tests of the
    /// click rules turn it off: a ci-step Mac has no window server session to track a press in.
    var tracksPresses = true
    /// Runs a command on the selection (``FileGridView`` sets it).
    var onCommand: ((FileGridCommand) -> Void)?
    /// The context menu for the current selection.
    var menuForSelection: (() -> NSMenu?)?
    /// The files Quick Look shows: the selection, in grid order.
    var previewURLs: () -> [URL] = { [] }
    /// The drop outline came on or went off.
    var onDropHighlight: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (Int(event.keyCode), flags.subtracting([.numericPad, .function])) {
        case (kVK_Space, []):
            toggleQuickLook()
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            onCommand?(.rename)
        case (kVK_ANSI_O, [.command]), (kVK_DownArrow, [.command]):
            onCommand?(.open)
        case (kVK_Delete, [.command]), (kVK_ForwardDelete, [.command]):
            onCommand?(.trash)
        case (kVK_ANSI_C, [.command, .option]):
            onCommand?(.copyPath)
        case (kVK_ANSI_A, [.command]):
            selectAll(nil)
        case (kVK_Escape, []) where !selectionIndexPaths.isEmpty:
            applySelection?(currentSelection().cleared())
        default:
            super.keyDown(with: event)
        }
    }

    /// Edit > Copy and Cmd-C.
    @objc func copy(_ sender: Any?) {
        onCommand?(.copy)
    }

    /// Edit > Select All and Cmd-A: every tile (the anchor stays).
    override func selectAll(_ sender: Any?) {
        guard let applySelection else { return super.selectAll(sender) }
        applySelection(currentSelection().selectingAll(count: numberOfItems(inSection: 0)))
    }

    /// A click on a tile goes through ``FileGridSelection``; AppKit's own tracking still runs
    /// (with the modifiers taken off) so a press that moves drags the selected tiles out. A click
    /// on empty space (rubber band, select none) and Control-click (the menu) stay AppKit's.
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control), let applySelection,
              let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            if event.clickCount == 2, !selectionIndexPaths.isEmpty { onCommand?(.open) }
            return
        }
        let kind = FileGridClickKind(modifiers: flags)
        let next = currentSelection().clicking(path.item, kind)
        window?.makeFirstResponder(self)
        dragBegan = false
        if kind == .select {
            // AppKit keeps a multi-selection under the press so it can be dragged, then
            // collapses it on release; the model's result is applied after a release without a drag.
            if tracksPresses { super.mouseDown(with: event) }
            applySelection(dragBegan ? FileGridSelection(indices: currentSelection().indices, anchor: path.item) : next)
            if event.clickCount == 2, !selectionIndexPaths.isEmpty { onCommand?(.open) }
            return
        }
        applySelection(next)
        // Cmd-click that took the tile out: nothing to drag.
        guard next.indices.contains(path.item) else { return }
        if tracksPresses { super.mouseDown(with: Self.unmodified(event)) }
        // AppKit's plain-click tracking may have collapsed the selection on release.
        applySelection(next)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            if let applySelection {
                applySelection(currentSelection().clicking(path.item, .select))
            } else {
                deselectAll(nil)
                selectItems(at: [path], scrollPosition: [])
            }
        }
        return menuForSelection?()
    }

    /// `event` without its modifier keys, so AppKit tracks it as a plain press.
    private static func unmodified(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: [], timestamp: event.timestamp,
                           windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDropHighlight?(false)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        onDropHighlight?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        onDropHighlight?(false)
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if !previewURLs().isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Reloads the panel after the selection moved (arrow keys with the panel open).
    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        panel.reloadData()
    }

    // Quick Look's panel-controller methods are a nonisolated NSObject category it calls on the
    // main thread; off main (never seen) the change hops there instead of trapping.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel?) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
        guard let panel else { return }
        // main-hop-allow: Quick Look's panel-control callback off main (never seen): begin and end keep their order on main
        guard Thread.isMainThread else { Task { @MainActor in attach(panel, true) }; return }
        MainActor.assumeIsolated { attach(panel, true) } // main-proof: checked Thread.isMainThread above
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
        guard let panel else { return }
        // main-hop-allow: Quick Look's panel-control callback off main (never seen): begin and end keep their order on main
        guard Thread.isMainThread else { Task { @MainActor in attach(panel, false) }; return }
        MainActor.assumeIsolated { attach(panel, false) } // main-proof: checked Thread.isMainThread above
    }

    private func attach(_ panel: QLPreviewPanel, _ on: Bool) {
        panel.dataSource = on ? self : nil
        panel.delegate = on ? self : nil
    }
}

extension FileGridCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        previewURLs().count
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        let urls = previewURLs()
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    /// Arrow keys in the panel move the grid's selection, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel?, handle event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            keyDown(with: event)
            return true
        default:
            return false
        }
    }
}
