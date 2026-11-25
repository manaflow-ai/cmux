public import AppKit

/// The floating chat's top edge: a drag there moves the panel. The page
/// under it would take the press, and a web view never moves its window.
public final class FloatingChatGrip: NSView {
    public static let height: CGFloat = 12

    override public var mouseDownCanMoveWindow: Bool { true }

    override public func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
