import AppKit

/// Intercepts only forbidden live surface drags, leaving ordinary hit testing alone.
@MainActor
final class CloudSurfaceDropGateView: NSView {
    weak var workspace: Workspace? {
        didSet { if oldValue !== workspace { feedback.clear() } }
    }
    var isActive = false {
        didSet { if !isActive { feedback.clear() } }
    }
    let feedback = SurfaceDropFeedback()
    private let sourceResolver: PaneTransferSourceResolver

    init(frame: NSRect, sourceResolver: PaneTransferSourceResolver = PaneTransferSourceResolver()) {
        self.sourceResolver = sourceResolver
        super.init(frame: frame)
        registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    func rejection(for pasteboard: NSPasteboard) -> SurfaceTransferRejection? {
        guard isActive, let workspace,
              DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboard.types) else { return nil }
        guard let transfer = sourceResolver.transfer(from: pasteboard),
              let source = sourceResolver.source(for: transfer) else {
            return workspace.surfaceOwnershipPolicy.rejection(for: nil)
        }
        return workspace.surfaceDropRejection(transfer, source: source)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, bounds.contains(point),
              WindowInputRoutingContext(event: NSApp.currentEvent).allowsPaneDropHitTesting else { return nil }
        let pasteboard = NSPasteboard(name: .drag)
        guard sourceResolver.transfer(from: pasteboard) != nil else { return nil }
        return rejection(for: pasteboard) == nil ? nil : self
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        feedback.update(rejection(for: sender.draggingPasteboard), over: self)
        return []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        feedback.clear()
        return false
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { feedback.clear() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { feedback.clear() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { feedback.clear() }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { feedback.clear() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}
