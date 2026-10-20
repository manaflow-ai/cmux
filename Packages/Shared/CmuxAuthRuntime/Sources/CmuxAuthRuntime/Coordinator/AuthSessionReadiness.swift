/// Whether the session can serve tokens (``AuthCoordinator/sessionReadiness``).
public enum AuthSessionReadiness: Sendable, Equatable {
    /// No session.
    case signedOut
    /// A sign-in is still completing: ``AuthCoordinator/isAuthenticated`` can
    /// already read true, but ``AuthCoordinator/currentTokens()`` refuses
    /// until the sign-in ends.
    case completing
    /// Signed in as `accountID`, and ``AuthCoordinator/currentTokens()`` serves its tokens.
    case ready(accountID: String)
}
