import AppKit

final class ResizeGripperNSView: NSView {
    var onBegin: () -> (CGFloat, CGFloat) = { (0, 0) }
    var onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void = { _, _, _, _ in }
    var onEnd: () -> Void = {}

    private var pressLocation: NSPoint?
    private var pressStartWidth: CGFloat = 0
    private var pressStartHeight: CGFloat = 0

    private static let diagonalResizeCursor: NSCursor = {
        // AppKit ships a NW–SE diagonal resize cursor for window corners but doesn't expose
        // it publicly. It has lived under this selector for years and is widely used by Mac
        // apps that need a diagonal resize affordance.
        let selector = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if let method = NSCursor.responds(to: selector) ? NSCursor.perform(selector) : nil,
           let cursor = method.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return NSCursor.crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.diagonalResizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        // NSEvent.mouseLocation is screen-coordinate and stable while the popover resizes.
        pressLocation = NSEvent.mouseLocation
        let (w, h) = onBegin()
        pressStartWidth = w
        pressStartHeight = h
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        // Screen-y grows upward; popover should grow as the pointer moves down (toward
        // smaller screen-y), so invert.
        let dy = start.y - current.y
        onDrag(pressStartWidth, pressStartHeight, dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        onEnd()
    }
}
