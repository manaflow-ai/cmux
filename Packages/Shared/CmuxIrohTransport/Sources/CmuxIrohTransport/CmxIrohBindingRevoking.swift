/// Broker capability for idempotently revoking an account-owned binding.
public protocol CmxIrohBindingRevoking: Sendable {
    /// Revokes one binding after authenticating its owning account.
    ///
    /// Repeating a confirmed request for the same binding must remain safe.
    ///
    /// - Parameter bindingID: The broker-owned lowercase binding UUID.
    func revoke(bindingID: String) async throws

    /// Revokes an older same-device binding through the account-scoped stale
    /// cleanup route, rather than pretending the caller owns that ID.
    func revokeStale(bindingID: String) async throws
}

/// Default stale-binding behavior for brokers without a dedicated route.
public extension CmxIrohBindingRevoking {
    /// Falls back to ordinary revocation for conformers without a stale route.
    func revokeStale(bindingID: String) async throws {
        try await revoke(bindingID: bindingID)
    }
}
