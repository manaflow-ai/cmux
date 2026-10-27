import AppKit

/// cmux: the pointing hand over a link in the transcript (Lawrence 2026-10-19: "when i hover on
/// link it needs to turn into cursor pointer"): text links, Markdown links and link cards, the
/// same hit test a click uses (`ChatController.linkURL(at:)`), so a refused link keeps the arrow.
/// The tracking area covers the visible transcript only, and only while the window is key, so the
/// pointer costs nothing while the person types or works in another window.
extension TranscriptDocumentView {
    /// Marks the link-hover tracking area among the view's areas.
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
        updateLinkCursor(event, always: false)
        controller?.onPointerMoved?(window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    override func cursorUpdate(with event: NSEvent) { updateLinkCursor(event, always: true) }

    override func mouseExited(with event: NSEvent) {
        if overLink { overLink = false; NSCursor.arrow.set() }
        controller?.onPointerMoved?(nil)
    }

    /// Whether the pointer is over a link now (the hand is set).
    private var overLink: Bool {
        get { linkHoverStateKey.value(on: self) as? Bool ?? false }
        set { linkHoverStateKey.set(newValue, on: self) }
    }

    /// Sets the hand over a link, else the arrow (`always`: on entering, else only when the
    /// pointer just left a link).
    private func updateLinkCursor(_ event: NSEvent, always: Bool) {
        guard let controller else { return }
        let point = controller.host.convert(event.locationInWindow, from: nil)
        let onLink = controller.linkURL(at: point) != nil
        if onLink { NSCursor.pointingHand.set() } else if overLink || always { NSCursor.arrow.set() }
        overLink = onLink
    }
}

/// The associated-object key of ``TranscriptDocumentView``'s link-hover state (an extension
/// cannot add a stored property to the vendored view).
private let linkHoverStateKey = AssociationKey()
