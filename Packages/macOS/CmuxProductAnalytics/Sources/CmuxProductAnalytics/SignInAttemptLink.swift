/// How a sign-in callback or success is tied to its `attempt_id`.
public enum SignInAttemptLink: String, Sendable, CaseIterable {
    /// The callback carried the state that attempt's browser window issued.
    case state
    /// The callback carried no state (the embedded browser's handoff or an
    /// approved unsolicited callback). It is credited to the pending sign-in,
    /// which did not necessarily cause it.
    case unlinked = "none"
}
