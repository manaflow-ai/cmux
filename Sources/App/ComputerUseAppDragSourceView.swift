import AppKit

/// Starts a Finder-compatible drag containing the installed helper app URL.
@MainActor
final class ComputerUseAppDragSourceView: NSView, NSDraggingSource {
    private var helperAppURL: URL?
    private var helperIcon: NSImage?
    private var onDragEnded: ((NSDragOperation) -> Void)?
    private var activePasteboardItem: NSPasteboardItem?

    override var mouseDownCanMoveWindow: Bool { false }

    func update(
        helperAppURL: URL?,
        helperIcon: NSImage?,
        onDragEnded: @escaping (NSDragOperation) -> Void
    ) {
        self.helperAppURL = helperAppURL
        self.helperIcon = helperIcon
        self.onDragEnded = onDragEnded
    }

    override func mouseDown(with event: NSEvent) {
        // Keep the initial press in this view so dragging the card never moves
        // the onboarding window. AppKit sends the threshold-crossing event to
        // `mouseDragged(with:)` below.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let helperAppURL else { return }

        let pasteboardItem = Self.pasteboardItem(for: helperAppURL)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let icon = dragIcon(for: helperAppURL)
        let location = convert(event.locationInWindow, from: nil)
        let previewSize = NSSize(width: 64, height: 64)
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - previewSize.width / 2,
                y: location.y - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: icon
        )

        activePasteboardItem = pasteboardItem
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        activePasteboardItem = nil
        onDragEnded?(operation)
    }

    static func pasteboardItem(for helperAppURL: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(helperAppURL.absoluteString, forType: .fileURL)
        return item
    }

    private func dragIcon(for helperAppURL: URL) -> NSImage {
        let source = helperIcon ?? NSWorkspace.shared.icon(forFile: helperAppURL.path)
        let icon = (source.copy() as? NSImage) ?? source
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
}
