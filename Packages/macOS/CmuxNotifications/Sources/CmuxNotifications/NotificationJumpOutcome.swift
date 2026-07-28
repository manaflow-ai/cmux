/// The observable result of attempting to open the latest unread target.
public enum NotificationJumpOutcome: Sendable, Equatable {
    /// An unread notification or workspace was opened.
    case completed
    /// The notification store is available, but no unread target opened.
    case notApplicable
    /// The notification store is unavailable.
    case targetUnavailable
}
