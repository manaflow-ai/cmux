/// What a user's sign-in request did. Every request sends
/// `cmux_sign_in_started`; only `opened` begins an attempt with results.
public enum SignInStartOutcome: String, Sendable, CaseIterable {
    /// A new browser sign-in attempt opened.
    case opened
    /// An attempt that already continues in the default browser was shown
    /// again; no new attempt.
    case reused
    /// The app was already signed in, so no attempt opened (socket sign-in).
    case alreadySignedIn = "already_signed_in"
}

/// The result of one sign-in request, as `cmux_sign_in_started` reports it.
public enum SignInStart: Equatable, Sendable {
    /// A new attempt opened. `replaced` is the earlier opened attempt that had
    /// no result yet; it gets a result only if a callback carrying its own
    /// state still arrives.
    case opened(SignInAttemptID, replaced: SignInAttemptID?)
    /// No attempt opened; the request has no `attempt_id` and no results.
    case noAttempt(SignInStartOutcome)

    public var outcome: SignInStartOutcome {
        switch self {
        case .opened: .opened
        case let .noAttempt(outcome): outcome
        }
    }
}
