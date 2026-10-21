import AppKit
import Carbon.HIToolbox
import Quartz

/// The grid's collection view: turns keys, double clicks and right clicks
/// into ``FileGridCommand`` values for ``FileGridView`` and drives the Quick
/// Look panel over the selection (Space, as in Finder).
final class FileGridCollectionView: NSCollectionView {
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
        default:
            super.keyDown(with: event)
        }
    }

    /// Edit > Copy and Cmd-C.
    @objc func copy(_ sender: Any?) {
        onCommand?(.copy)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, !selectionIndexPaths.isEmpty { onCommand?(.open) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            deselectAll(nil)
            selectItems(at: [path], scrollPosition: [])
        }
        return menuForSelection?()
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

    // Quick Look's panel-controller methods are an NSObject category it calls on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension FileGridCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = previewURLs()
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    /// Arrow keys in the panel move the grid's selection, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
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
