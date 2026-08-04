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

    /// Runs one registration/policy refresh round now, as if the renewal
    /// timer had fired, and waits for that round to settle. Called when an
    /// external signal (a server-directed presence nudge) says broker-side
    /// state for this binding changed, so the host re-registers and re-reads
    /// policy within seconds instead of waiting out the hint-expiry renewal.
    /// Coalesces with an in-flight refresh through the standard pending-replay
    /// path; no-op unless active. Await-to-settled matters for the caller: a
    /// refresh that discovers the binding was revoked or REPLACED (different
    /// binding id) fails closed into the terminal `.failed` phase, and the
    /// composition root reads the post-refresh snapshot to decide whether a
    /// full rebuild is needed.
    ///
    /// This is deliberately the SAME round the renewal timer runs, including
    /// its mutate-then-detect ordering (register first, notice a changed
    /// binding id after): a nudge changes when the round happens, never what
    /// it does. Teaching a superseded host to stand down without re-taking
    /// the broker's newest-wins slot needs authoritative disposition from the
    /// broker, which belongs to the nudge-emission hook (it fires from the
    /// mutation and knows why), not to this accelerator.
    public func requestRegistrationRefresh() async {
        guard lifecyclePhase == .active,
              registrationRefreshEnabled else { return }
        scheduleRegistrationRefresh(revision: lifecycleRevision)
        // Await across the coalesced replay, not just the round that was
        // running when this call arrived: a signal landing mid-round only
        // sets the pending bit, and the running round's completion schedules
        // one replay task. The caller's decision (rebuild on `.failed`) must
        // observe the state AFTER that replay. The loop is bounded: each
        // awaited task nils itself on completion unless a replay was pending,
        // and replays do not self-perpetuate. A retry scheduled after a
        // transient failure is deliberately NOT awaited (it can be minutes
        // out); the runtime is not terminally failed in that state.
        while let task = registrationRefreshTask {
            await task.value
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
