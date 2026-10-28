public import Foundation

/// Tells ``MainFrameBudget`` whether a person's input is waiting for the main thread, so budgeted
/// work yields to it (Chrome's input-pending check before a scheduled task).
@MainActor
public protocol InputPendingSource: AnyObject {
    /// Whether input for this app that a person waits on (a key, a mouse button, a scroll begin or
    /// a drag) has been generated but not dispatched yet.
    ///
    /// - Parameter uptime: Now, in seconds since boot (the `NSEvent.timestamp` base).
    func hasPendingInput(uptime: TimeInterval) -> Bool

    /// Whether pending input includes a mouse button, a scroll begin or a drag: input that goes to
    /// the view under the pointer, not to the key window. The default is ``hasPendingInput(uptime:)``
    /// (a source that does not tell kinds apart counts every input as pointer input).
    ///
    /// - Parameter uptime: Now, in seconds since boot.
    func hasPendingPointerInput(uptime: TimeInterval) -> Bool
}

extension InputPendingSource {
    /// The default: any pending input counts (``hasPendingInput(uptime:)``).
    public func hasPendingPointerInput(uptime: TimeInterval) -> Bool {
        hasPendingInput(uptime: uptime)
    }
}
