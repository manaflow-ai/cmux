/// Broker capability for idempotently revoking an account-owned binding.
public protocol CmxIrohBindingRevoking: Sendable {
    /// Revokes one binding after authenticating its owning account.
    ///
    /// Repeating a confirmed request for the same binding must remain safe.
    ///
    /// - Parameter bindingID: The broker-owned lowercase binding UUID.
    func revoke(bindingID: String) async throws
}
