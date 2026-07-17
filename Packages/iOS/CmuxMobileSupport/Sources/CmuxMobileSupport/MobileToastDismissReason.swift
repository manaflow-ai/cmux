/// The event that removed a toast from the presentation queue.
public enum MobileToastDismissReason: Equatable, Sendable {
    /// The toast reached its configured lifetime.
    case timedOut

    /// The user dismissed the toast directly.
    case user

    /// The user selected the toast's action.
    case action

    /// The presenting feature dismissed the toast.
    case programmatic

    /// A newer or more important toast superseded this toast.
    case replaced
}
