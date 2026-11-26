import Foundation

/// What became of a row handed to the local notification store.
public enum CloudNotificationDeliveryOutcome: Equatable, Sendable {
    /// A local record exists; the row is consumed.
    case delivered
    /// Nothing here could take the row yet (no store, a placement that
    /// vanished between resolution and delivery); the next fold retries it.
    case declined
    /// This Mac will never show the row (an admission drop, a muted
    /// workspace): it is consumed and acknowledged as read at once, so no
    /// indicator anywhere waits for a dismissal that cannot happen.
    case suppressed
}
