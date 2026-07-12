import AppKit
import CmuxAppKitSupportUI

final class ResizeGripperNSView: NSView {
    var onBegin: () -> (CGFloat, CGFloat) = { (0, 0) }
    var onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void = { _, _, _, _ in }
    var onEnd: () -> Void = {}

    private var pressLocation: NSPoint?
    private var pressStartWidth: CGFloat = 0
    private var pressStartHeight: CGFloat = 0


    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: CmuxResizeCursors.diagonalNWSE)
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
