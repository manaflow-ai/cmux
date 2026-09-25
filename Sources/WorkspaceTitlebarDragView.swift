import AppKit
import Bonsplit

/// An explicit drag handle confined to the tab strip's reserved leading inset.
final class WorkspaceTitlebarDragView: NSView {
    deinit {}

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        return capturesMouseDown(at: point, event: event) ? self : nil
    }

    func capturesMouseDown(at point: NSPoint, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              bounds.contains(point), let window, event.window === window,
              !window.styleMask.contains(.fullScreen),
              !isWindowDragSuppressed(window: window) else { return false }
        let windowPoint = convert(point, to: nil)
        // Layout can update the inset and tabs in adjacent passes. Yield to
        // their live regions even during that transition, and to native buttons.
        guard !BonsplitTabItemHitRegionRegistry.containsWindowPoint(windowPoint, in: window),
              !isMinimalModeTitlebarControlHit(window: window, locationInWindow: windowPoint) else { return false }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(type), !button.isHidden,
               button.convert(button.bounds, to: nil).contains(windowPoint) { return false }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard capturesMouseDown(at: convert(event.locationInWindow, from: nil), event: event),
              let window else { return }
        withTemporaryWindowMovableEnabled(window: window) {
            window.performDrag(with: event)
        }
    }
}
