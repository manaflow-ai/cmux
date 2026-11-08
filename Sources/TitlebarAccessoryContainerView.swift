import AppKit

final class TitlebarAccessoryContainerView: NSView {
    static func shouldResolveWindowDragHit(eventType: NSEvent.EventType?) -> Bool {
        eventType == nil || eventType == .leftMouseDown
    }

    /// Called with the new window (or nil) whenever AppKit moves this view.
    var onWindowChange: ((NSWindow?) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard Self.shouldResolveWindowDragHit(eventType: NSApp.currentEvent?.type) else {
            return super.hitTest(point)
        }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let result = handleTitlebarDoubleClick(
                window: window,
                behavior: .standardAction
            )
            if result.consumesEvent {
                return
            }
        }

        guard !isWindowDragSuppressed(window: window) else { return }

        if let window {
            withTemporaryWindowMovableEnabled(window: window) {
                window.performDrag(with: event)
            }
        } else {
            super.mouseDown(with: event)
        }
    }
}
