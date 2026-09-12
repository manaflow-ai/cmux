/// Supplies observable irx authentication state to a platform UI.
public protocol CmxIrxAuthenticationStatusProviding: AnyObject, Sendable {
    /// Returns the current credential-free irx authentication state.
    func irxAuthenticationState() async -> CmxIrxAuthenticationState

    /// Emits the current state followed by every later state transition.
    func irxAuthenticationStateUpdates() async
        -> AsyncStream<CmxIrxAuthenticationState>
}
