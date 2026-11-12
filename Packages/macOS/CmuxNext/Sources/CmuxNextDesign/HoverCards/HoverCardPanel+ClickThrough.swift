import AppKit

/// Clicks in the clear band around an interactive card (Lawrence 2026-10-20: the Update Ready
/// card's Hide did nothing). An interactive card's window takes mouse events over its whole
/// frame, and that frame keeps a clear band around the card (the shadow and the slide's room,
/// `windowMargin`) that reaches over what the card sits beside: the update card's top right
/// corner, where Hide is. The window server gives a click there to this window, whose views
/// find nothing under it, so it was lost. A press outside the card, and the drags and release
/// that follow it, go to the parent window at the same screen point, as if this window were not
/// there.
extension HoverCardPanel {
    private static let pressTypes: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let followTypes: Set<NSEvent.EventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                              .leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let moveTypes: Set<NSEvent.EventType> = [.mouseMoved, .mouseEntered, .mouseExited]
    private static let releaseTypes: Set<NSEvent.EventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]

    override func sendEvent(_ event: NSEvent) {
        // A move over this window (the card or its band) reaches none of the parent's tracking areas, so
        // the parent's hover is recomputed on it: a view under the band (the Updated card and its x,
        // https://github.com/manaflow-ai/cmux/issues/39248) lights and unlights as the pointer moves.
        if Self.moveTypes.contains(event.type), let parent { PointerHover.refresh(in: parent) }
        guard let parent, let forwarded = clickThrough(event, to: parent) else { return super.sendEvent(event) }
        parent.sendEvent(forwarded)
    }

    /// `event` as the parent window gets it when it belongs below this window, else nil.
    private func clickThrough(_ event: NSEvent, to parent: NSWindow) -> NSEvent? {
        let screen = convertPoint(toScreen: event.locationInWindow)
        if Self.pressTypes.contains(event.type) {
            forwardsPress = !presentedCardFrame.contains(screen)
        } else if !Self.followTypes.contains(event.type) {
            return nil
        }
        guard forwardsPress else { return nil }
        if Self.releaseTypes.contains(event.type) { forwardsPress = false }
        return NSEvent.mouseEvent(with: event.type, location: parent.convertPoint(fromScreen: screen), modifierFlags: event.modifierFlags,
                                  timestamp: event.timestamp, windowNumber: parent.windowNumber, context: nil,
                                  eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }
}
