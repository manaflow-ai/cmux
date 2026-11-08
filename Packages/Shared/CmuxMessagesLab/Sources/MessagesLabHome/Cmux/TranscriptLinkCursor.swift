import AppKit

/// Whether the pointer is over a link now (the hand is set).
private let overLinkKey = AssociationKey()

/// cmux: the pointing hand over a link in the transcript, as Messages shows it (issue 38178:
/// "Hovering a link shows the pointing-hand cursor"; this takes back the arrow of 2026-10-30 for
/// transcript links only, every other control keeps the arrow). Text links, Markdown links, link
/// chips and link cards use the same hit test a click uses (`ChatController.linkURL(at:)`), so a
/// refused link keeps the arrow. The tracking area reports pointer moves to the pane
/// (`onPointerMoved`) and covers the visible transcript only, and only while the window is key, so
/// the pointer costs nothing while the person types or works in another window.
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
        updateLinkCursor(at: event.locationInWindow, always: false)
        controller?.onPointerMoved?(window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    override func cursorUpdate(with event: NSEvent) { updateLinkCursor(at: event.locationInWindow, always: true) }

    override func mouseExited(with event: NSEvent) {
        if overLink { overLink = false; NSCursor.arrow.set() }
        controller?.onPointerMoved?(nil)
    }

    /// Whether the pointer is over a link now (the hand is set).
    var overLink: Bool {
        get { objc_getAssociatedObject(self, overLinkKey.pointer) as? Bool ?? false }
        set { objc_setAssociatedObject(self, overLinkKey.pointer, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Whether `windowPoint` is over a link a click would open.
    func isOverLink(_ windowPoint: CGPoint) -> Bool {
        guard let controller else { return false }
        return controller.linkURL(at: controller.host.convert(windowPoint, from: nil)) != nil
    }

    /// Sets the hand over a link, else the arrow (`always`: on a cursor update, else only when the
    /// pointer just left a link, so a move over plain text costs one hit test and no cursor set).
    func updateLinkCursor(at windowPoint: CGPoint, always: Bool) {
        let onLink = isOverLink(windowPoint)
        if onLink { NSCursor.pointingHand.set() } else if overLink || always { NSCursor.arrow.set() }
        overLink = onLink
    }
}
