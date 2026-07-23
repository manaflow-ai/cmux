/// The observable result of a notification action routed to captured workspace
/// and panel identities.
public enum ExplicitNotificationActionOutcome: Sendable, Equatable {
    /// The request completed, including when unread state already matched.
    case completed
    /// The target is live, but the requested action made no change and opened
    /// no next unread target.
    case notApplicable
    /// The notification store or a captured workspace or panel is unavailable.
    case targetUnavailable
}
