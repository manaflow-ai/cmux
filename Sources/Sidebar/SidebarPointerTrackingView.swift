import AppKit

/// One input-only AppKit tracking surface for the workspace sidebar viewport.
@MainActor
final class SidebarPointerTrackingView: NSView {
    var onPointerEvent: ((NSEvent) -> Void)?
    var onPointerExit: ((NSEvent) -> Void)?

    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        pointerTrackingArea = nextTrackingArea
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEvent?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerEvent?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?(event)
    }
}
