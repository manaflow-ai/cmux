public import AppKit
public import Foundation

/// Legacy mouse-event policy retained for CmuxFoundation source compatibility.
///
/// cmux no longer uses inferred mouse state, app activation, or Escape events
/// as drag-lifecycle authority. New drag implementations should clear state
/// from their native AppKit source completion callback instead.
public struct SidebarDragFailsafePolicy {
    /// The historical delay used by clients that still consume this policy.
    public static let clearDelay: TimeInterval = 0.15

    /// Creates the stateless compatibility policy.
    public init() {}

    /// Returns whether a client using the legacy policy would request cleanup.
    /// - Parameters:
    ///   - isDragActive: Whether that client currently presents a drag.
    ///   - isLeftMouseButtonDown: Whether the client observes the button down.
    /// - Returns: `true` when the legacy policy would request cleanup.
    public func shouldRequestClear(
        isDragActive: Bool,
        isLeftMouseButtonDown: Bool
    ) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    /// Returns whether legacy monitoring would request cleanup immediately.
    /// - Parameter isLeftMouseButtonDown: Whether the client observes the button down.
    /// - Returns: `true` when the legacy policy would request cleanup.
    public func shouldRequestClearWhenMonitoringStarts(
        isLeftMouseButtonDown: Bool
    ) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    /// Returns whether the event matched the legacy cleanup trigger.
    /// - Parameter eventType: The AppKit mouse event to classify.
    /// - Returns: `true` only for a left-mouse-up event.
    public func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}
