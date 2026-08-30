public import Foundation

/// Credential-free authentication state published by an irx mobile runtime.
public enum CmxIrxAuthenticationState: Equatable, Sendable {
    /// The runtime can use its current authenticated session.
    case ready
    /// The broker rejected the session and the user must sign in again.
    case reauthenticationRequired
}

/// Supplies observable irx authentication state to a platform UI.
public protocol CmxIrxAuthenticationStatusProviding: AnyObject, Sendable {
    /// Returns the current credential-free irx authentication state.
    func irxAuthenticationState() async -> CmxIrxAuthenticationState

    /// Emits the current state followed by every later state transition.
    func irxAuthenticationStateUpdates() async
        -> AsyncStream<CmxIrxAuthenticationState>
}
