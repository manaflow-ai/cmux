public import AppKit

/// Pure predicate deciding whether a passive hover tracker captures a hit-test.
///
/// A minimal-mode passthrough hover tracker should only claim a hit while it is
/// genuinely tracking hover: the point is inside its bounds, no mouse button is
/// pressed, and the current event is a passive hover event (or there is no
/// current event). For any active event (clicks, drags, key events) it must let
/// the hit pass through to the views underneath.
///
/// The tracker's configuration half (whether it captures passive hover hits at
/// all) is held as constructor-injected instance state; the latency-sensitive
/// `hitTest` call site builds one of these from its `capturesPassiveHits` flag
/// and feeds the per-call event/geometry inputs. The live `NSApp.currentEvent`,
/// `NSEvent.pressedMouseButtons`, and bounds sampling stay in the view and feed
/// these arguments; nothing about the decision reaches into view state.
public struct PassthroughHoverCapturePolicy: Sendable, Equatable {
    /// Whether the tracker is configured to capture passive hover hits at all.
    public let capturesPassiveHits: Bool

    /// Creates a capture policy from the tracker's passive-hit configuration.
    /// - Parameter capturesPassiveHits: Whether the tracker captures passive
    ///   hover hits at all.
    public init(capturesPassiveHits: Bool) {
        self.capturesPassiveHits = capturesPassiveHits
    }

    /// Whether a passive hover tracker captures a hit given the current state.
    ///
    /// - Parameters:
    ///   - eventType: The current `NSApp.currentEvent` type, or `nil` when there
    ///     is no current event.
    ///   - pressedMouseButtons: `NSEvent.pressedMouseButtons` at the time of the
    ///     hit-test.
    ///   - boundsContainsPoint: Whether the hit-tested point lies within the
    ///     tracker's bounds.
    /// - Returns: `true` when the tracker should capture the hit, `false` to let
    ///   it pass through.
    public func capturesHit(
        eventType: NSEvent.EventType?,
        pressedMouseButtons: Int,
        boundsContainsPoint: Bool
    ) -> Bool {
        guard boundsContainsPoint, pressedMouseButtons == 0 else { return false }
        switch eventType {
        case nil, .mouseMoved, .mouseEntered, .mouseExited:
            return capturesPassiveHits
        default:
            return false
        }
    }
}
