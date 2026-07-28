/// Synchronous disposition of a user-requested update action.
public enum UpdateRequestOutcome: Sendable, Equatable {
    /// The updater accepted or queued work for this request.
    case accepted
    /// Policy intentionally suppressed the request without starting updater work.
    case suppressed
    /// An update check or installation already owns the updater lifecycle.
    case inProgress
    /// The updater synchronously failed to accept the request and surfaced an error.
    case failed
}
