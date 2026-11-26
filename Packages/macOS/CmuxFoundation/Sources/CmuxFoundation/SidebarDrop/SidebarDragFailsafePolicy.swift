public import AppKit
public import Foundation

/// Legacy compatibility policy for clients that still classify drag failures.
///
/// The application no longer uses inferred mouse, activation, or Escape
/// signals to end a drag; native AppKit source completion is authoritative.
public struct SidebarDragFailsafePolicy {
    /// Historical delay retained for source compatibility.
    public static let clearDelay: TimeInterval = 0.15

    /// Creates the stateless compatibility policy.
    public init() {}

    /// Returns whether the legacy policy would request cleanup.
    public func shouldRequestClear(
        isDragActive: Bool,
        isLeftMouseButtonDown: Bool
    ) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    /// Returns whether legacy monitoring would request immediate cleanup.
    public func shouldRequestClearWhenMonitoringStarts(
        isLeftMouseButtonDown: Bool
    ) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    /// Returns whether the event matched the legacy cleanup trigger.
    public func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}
