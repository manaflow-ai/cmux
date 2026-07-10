/// The non-secret binding captured before local sign-out state is destroyed.
public struct CmxIrohClientSignOutPreparation: Equatable, Sendable {
    /// The broker binding to revoke with the auth tokens captured by sign-out.
    public let bindingID: String?

    /// Creates a sign-out handoff after local endpoint and credential teardown.
    ///
    /// - Parameter bindingID: The prior broker binding, or `nil` before registration.
    public init(bindingID: String?) {
        self.bindingID = bindingID
    }

    /// Revokes the captured binding with a broker authenticated from captured tokens.
    ///
    /// A missing binding is a successful no-op. Callers should treat network
    /// failure as best-effort and must never reconstruct local state from it.
    ///
    /// - Parameter broker: A broker client whose token source holds the
    ///   access and refresh tokens captured before auth's local teardown.
    /// - Throws: The broker revocation error for an existing binding.
    public func revoke(using broker: any CmxIrohClientBrokerServing) async throws {
        guard let bindingID else { return }
        try await broker.revoke(bindingID: bindingID)
    }
}
