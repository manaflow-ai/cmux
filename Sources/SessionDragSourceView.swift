import AppKit

/// Native pointer source whose bounds exactly match one rendered Vault row.
@MainActor
final class SessionDragSourceView: NSView {
    private struct PendingDrag {
        let entry: SessionEntry
        let mouseDownEvent: NSEvent
        let startPoint: NSPoint
    }

    private(set) var entry: SessionEntry
    private(set) var beginDrag: SessionDragBeginAction
    private var onDoubleClick: @MainActor () -> Void
    private var pendingDrag: PendingDrag?
    private let dragThresholdSquared: CGFloat = 16

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(
        frame frameRect: NSRect = .zero,
        entry: SessionEntry,
        beginDrag: @escaping SessionDragBeginAction,
        onDoubleClick: @escaping @MainActor () -> Void
    ) {
        self.entry = entry
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        entry: SessionEntry,
        beginDrag: @escaping SessionDragBeginAction,
        onDoubleClick: @escaping @MainActor () -> Void
    ) {
        self.entry = entry
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown:
            return event.modifierFlags.contains(.control) ? nil : self
        case .leftMouseDragged, .leftMouseUp:
            return self
        default:
            // Hover, help, and contextual-menu events remain owned by the
            // SwiftUI row underneath this transparent source view.
            return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        pendingDrag = nil
        guard !event.modifierFlags.contains(.control),
              let window,
              event.windowNumber == window.windowNumber else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        pendingDrag = PendingDrag(
            entry: entry,
            mouseDownEvent: event,
            startPoint: point
        )
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.mouseDown agent=\(entry.agent.rawValue) clicks=\(event.clickCount)"
        )
#endif
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pendingDrag,
              let window,
              event.windowNumber == window.windowNumber else {
            self.pendingDrag = nil
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let deltaX = point.x - pendingDrag.startPoint.x
        let deltaY = point.y - pendingDrag.startPoint.y
        guard (deltaX * deltaX) + (deltaY * deltaY) >= dragThresholdSquared else {
            return
        }
        self.pendingDrag = nil

        let image = dragImage() ?? NSImage(size: bounds.size)
        _ = beginDrag(
            pendingDrag.entry,
            self,
            pendingDrag.mouseDownEvent,
            bounds,
            image
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingDrag else { return }
        self.pendingDrag = nil
        guard pendingDrag.mouseDownEvent.clickCount == 2 else { return }
        onDoubleClick()
    }

    override func cancelOperation(_ sender: Any?) {
        pendingDrag = nil
        super.cancelOperation(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pendingDrag = nil
    }

    private func dragImage() -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let contentFrame = convert(bounds, to: contentView)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(
            in: contentFrame
        ) else {
            return nil
        }
        contentView.cacheDisplay(in: contentFrame, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
