/// Credential-free authentication state published by an irx mobile runtime.
public enum CmxIrxAuthenticationState: Equatable, Sendable {
    /// The runtime can use its current authenticated session.
    case ready
    /// The broker rejected the session and the user must sign in again.
    case reauthenticationRequired
}
