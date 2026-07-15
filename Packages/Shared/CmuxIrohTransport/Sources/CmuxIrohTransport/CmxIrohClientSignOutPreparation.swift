/// The non-secret binding captured before local sign-out state is destroyed.
public struct CmxIrohSignOutPreparation: Equatable, Sendable {
    /// The account-and-tag-scoped binding queued before local teardown.
    public let pendingRevocation: CmxIrohPendingRevocation?

    /// Whether the first device-only persistence attempt succeeded.
    public let wasPersisted: Bool

    /// The broker binding to revoke, or `nil` before registration.
    public var bindingID: String? { pendingRevocation?.bindingID }

    /// Creates a sign-out handoff after local endpoint and credential teardown.
    ///
    /// - Parameters:
    ///   - pendingRevocation: The validated prior binding, or `nil` before registration.
    ///   - wasPersisted: Whether it was durably queued before local teardown.
    public init(
        pendingRevocation: CmxIrohPendingRevocation?,
        wasPersisted: Bool
    ) {
        self.pendingRevocation = pendingRevocation
        self.wasPersisted = pendingRevocation == nil || wasPersisted
    }

    /// Revokes the captured binding with a broker authenticated from captured tokens.
    ///
    /// A missing binding is a successful no-op. If initial persistence failed,
    /// this method retries the durable enqueue before contacting the broker.
    ///
    /// - Parameter broker: A broker client whose token source holds the
    ///   access and refresh tokens captured before auth's local teardown.
    /// - Parameter pendingRevocations: The same device-only outbox used by the runtime.
    /// - Throws: The broker revocation error for an existing binding.
    public func revoke(
        using broker: any CmxIrohClientBrokerServing,
        pendingRevocations: CmxIrohPendingRevocationOutbox
    ) async throws {
        guard let pendingRevocation else { return }
        if !wasPersisted {
            try await pendingRevocations.enqueue(pendingRevocation)
        }
        try await pendingRevocations.revokePending(
            accountID: pendingRevocation.accountID,
            beforeRegisteringTag: pendingRevocation.tag,
            using: broker
        )
    }
}

/// The iOS name for the shared sign-out handoff.
public typealias CmxIrohClientSignOutPreparation = CmxIrohSignOutPreparation

/// The macOS name for the shared sign-out handoff.
public typealias CmxIrohHostSignOutPreparation = CmxIrohSignOutPreparation
