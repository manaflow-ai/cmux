public import AppKit

/// The passive-hover hit-test decision for the minimal-mode titlebar passthrough
/// tracker: it answers whether the hover-tracking view should claim a hit-test
/// point for itself (revealing the hidden controls) or pass the event through to
/// the view behind it.
///
/// The tracker only ever captures *passive* hover traffic (a `nil`, mouse-moved,
/// mouse-entered, or mouse-exited event with no buttons pressed) and only when
/// `capturesPassiveHits` is set; any pressed button, an out-of-bounds point, or a
/// non-hover event type passes through. Holding the inputs as a value keeps the
/// decision testable in isolation from the live `NSEvent`/`NSView` it is derived
/// from at the call site.
public struct PassthroughHoverHitDecision: Equatable, Sendable {
    /// Whether the tracker is configured to capture passive hover traffic.
    public var capturesPassiveHits: Bool
    /// The event type under evaluation, or `nil` when there is no current event.
    public var eventType: NSEvent.EventType?
    /// The mouse buttons currently pressed (`NSEvent.pressedMouseButtons`).
    public var pressedMouseButtons: Int
    /// Whether the hit-test point falls inside the tracking view's bounds.
    public var boundsContainsPoint: Bool

    /// Creates a decision from the raw hit-test inputs.
    public init(
        capturesPassiveHits: Bool,
        eventType: NSEvent.EventType?,
        pressedMouseButtons: Int,
        boundsContainsPoint: Bool
    ) {
        self.capturesPassiveHits = capturesPassiveHits
        self.eventType = eventType
        self.pressedMouseButtons = pressedMouseButtons
        self.boundsContainsPoint = boundsContainsPoint
    }

    /// Whether the tracking view should claim the hit point for itself, revealing
    /// the hover controls, instead of passing the event through.
    public var capturesHit: Bool {
        guard boundsContainsPoint, pressedMouseButtons == 0 else { return false }
        switch eventType {
        case nil, .mouseMoved, .mouseEntered, .mouseExited:
            return capturesPassiveHits
        default:
            return false
        }
    }
}
