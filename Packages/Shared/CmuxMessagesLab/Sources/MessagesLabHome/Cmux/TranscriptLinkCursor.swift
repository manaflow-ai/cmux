import AppKit

/// cmux: the transcript shows the arrow over its links too, as native macOS apps do (user
/// 2026-10-30: "change all pointers back to cursor-default"; this replaces the pointing hand of
/// Lawrence 2026-10-19). The tracking area reports pointer moves to the pane (`onPointerMoved`)
/// and covers the visible transcript only, and only while the window is key, so the pointer costs
/// nothing while the person types or works in another window.
extension TranscriptDocumentView {
    /// Marks the pointer tracking area among the view's areas.
    private static let linkHoverKey = "cmux.linkHover"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?[Self.linkHoverKey] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: [Self.linkHoverKey: true]))
    }

    // Not passed up the responder chain: the pane host's own hover (the field's attachments)
    // has its own tracking area.
    override func mouseMoved(with event: NSEvent) {
        controller?.onPointerMoved?(window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseExited(with event: NSEvent) {
        controller?.onPointerMoved?(nil)
    }
}
