import AppKit
import CmuxWindowing

final class TitlebarAccessoryContainerView: NSView {
    static func shouldResolveWindowDragHit(eventType: NSEvent.EventType?) -> Bool {
        eventType == nil || eventType == .leftMouseDown
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard Self.shouldResolveWindowDragHit(eventType: NSApp.currentEvent?.type) else {
            return super.hitTest(point)
        }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let result = TitlebarDoubleClickHandlingResult.handle(
                window: window,
                behavior: .standardAction
            )
            if result.consumesEvent {
                return
            }
        }

        guard window?.isWindowDragSuppressed != true else { return }

        if let window {
            window.withTemporaryWindowMovableEnabled {
                window.performDrag(with: event)
            }
        } else {
            super.mouseDown(with: event)
        }
    }
}
