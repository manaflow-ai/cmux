public import CMUXMobileCore
import Foundation

extension CmxIrohHostRuntime {
    public func snapshot() -> CmxIrohHostRuntimeSnapshot {
        currentSnapshot
    }

    /// Returns the most recently admitted live path with coordinates removed.
    ///
    /// Relay attribution succeeds only when the selected relay is present in
    /// the exact verified effective policy installed by the composition root.
    ///
    /// - Parameter relayPolicy: The current verified effective relay policy.
    /// - Returns: A credential-free path category safe for settings and diagnostics.
    public func selectedTransportPath(
        relayPolicy: CmxIrohEffectiveRelayPolicy?
    ) async -> CmxIrohSelectedTransportPath {
        guard let id = activePathConnectionOrder.last,
              let connection = activePathConnections[id] as? any CmxIrohConnectionPathInspecting else {
            return .unavailable
        }
        let observed = await connection.observedSelectedPath()
        return CmxIrohSelectedTransportPathClassifier(policy: relayPolicy)
            .classify(observed)
    }

    /// Emits when admitted connection lifecycle may alter the selected path.
    ///
    /// Consumers re-read ``selectedTransportPath(relayPolicy:)`` for the
    /// credential-free value. The stream never carries raw path data.
    public func selectedTransportPathChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            selectedPathContinuations[id] = continuation
            continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSelectedPathContinuation(id: id) }
            }
        }
    }

    /// Returns current verified private alias material without broker path hints.
    public func lanAdvertisementContext() -> CmxIrohHostLANAdvertisementContext? {
        guard lifecyclePhase == .active,
              let localBinding,
              let lanRendezvous else { return nil }
        return CmxIrohHostLANAdvertisementContext(
            binding: localBinding,
            rendezvous: lanRendezvous
        )
    }

    /// Reads raw local direct addresses only for the interface-filtering publisher.
    public func localDirectAddresses() async -> [String] {
        guard lifecyclePhase == .active,
              let endpoint = try? await supervisor?.activeEndpoint() else { return [] }
        return await endpoint.localDirectAddresses()
    }

    /// Closes networking, durably queues revocation, then deactivates local state.
    ///
    /// The binding is captured and the lifecycle enters `signingOut` before the
    /// first suspension. Endpoint teardown and device-only persistence run
    /// concurrently. App-visible network state is cleared on either outcome.
    /// Persistence failure leaves identity state and the binding quarantined.
    /// Calling this method again while quarantined retries the durable enqueue.
    ///
    /// - Returns: The prior binding and whether it was durably queued.
    public func deactivateForSignOut() async -> CmxIrohHostSignOutPreparation {
        if let signOutOperation {
            return await signOutOperation.value
        }
        let requiresNetworkDeactivation = lifecyclePhase != .quarantined
        let pendingRevocation = localBinding.flatMap { binding in
            try? CmxIrohPendingRevocation(
                accountID: configuration.accountID,
                tag: configuration.tag,
                bindingID: binding.bindingID
            )
        }
        lifecyclePhase = .signingOut
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .signingOut,
            endpointID: currentSnapshot.endpointID,
            bindingID: pendingRevocation?.bindingID
        )

        let operation = Task {
            await self.performSignOut(
                pendingRevocation: pendingRevocation,
                requiresNetworkDeactivation: requiresNetworkDeactivation,
                revision: revision
            )
        }
        signOutOperation = operation
        return await operation.value
    }

    /// Creates a one-use five-minute offline invitation from the latest broker proof.
    public func createOfflinePairingInvitation() async throws -> CmxIrohOfflinePairingInvitation {
        guard lifecyclePhase == .active,
              let offlineSessions,
              let binding = localBinding,
              let attestation = endpointAttestation else {
            throw CmxIrohHostRuntimeError.inactive
        }
        return try await offlineSessions.createInvitation(
            acceptorAttestation: attestation.attestation,
            keys: attestation.grantVerificationKeys,
            acceptor: endpointExpectation(for: binding),
            now: now()
        )
    }
}
