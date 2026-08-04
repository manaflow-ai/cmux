import AppKit

/// Native accessory surface that preserves the minimal-mode hit routing used by
/// titlebar controls while allowing the surrounding chrome to drag the window.
final class TitlebarAccessoryContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard TitlebarAccessoryContainerView.shouldResolveWindowDragHit(
            eventType: NSApp.currentEvent?.type
        ) else {
            return super.hitTest(point)
        }
        guard let window else { return nil }

        let locationInWindow = convert(point, to: nil)
        guard isMinimalModeTitlebarControlHit(
            window: window,
            locationInWindow: locationInWindow
        ) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }
}
