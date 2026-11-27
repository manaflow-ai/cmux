public import Foundation

/// Tells ``MainFrameBudget`` whether a person's input is waiting for the main thread, so budgeted
/// work yields to it (Chrome's input-pending check before a scheduled task).
@MainActor
public protocol InputPendingSource: AnyObject {
    /// Whether a key or mouse-button event for this app has been generated but not dispatched yet.
    ///
    /// - Parameter uptime: Now, in seconds since boot (the `NSEvent.timestamp` base).
    func hasPendingInput(uptime: TimeInterval) -> Bool
}
