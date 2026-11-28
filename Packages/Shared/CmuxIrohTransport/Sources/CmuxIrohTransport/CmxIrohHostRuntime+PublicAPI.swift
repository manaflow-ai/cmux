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
    /// timer had fired, and waits for that round to settle. This remains the
    /// explicit/manual renewal entrypoint; pushed route revisions use the
    /// read-only ``reconcileConnectivityRevision(_:)`` path below.
    /// Coalesces with an in-flight refresh through the standard pending-replay
    /// path; no-op unless active. Await-to-settled matters for the caller: a
    /// refresh that discovers the binding was revoked or REPLACED (different
    /// binding id) fails closed into the terminal `.failed` phase, and the
    /// composition root reads the post-refresh snapshot to decide whether a
    /// full rebuild is needed.
    ///
    /// This is deliberately the same round the renewal timer runs, including
    /// its mutate-then-detect ordering. Server invalidations must never call
    /// this mutation path because reconciliation cannot retake a newer
    /// endpoint's broker slot.
    public func requestRegistrationRefresh() async {
        guard lifecyclePhase == .active,
              registrationRefreshEnabled else { return }
        scheduleRegistrationRefresh(
            revision: lifecycleRevision,
            forcePublication: true
        )
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

    /// Reconciles a pushed account route revision without registering again.
    ///
    /// The revision is only an acceleration hint. The complete v2 snapshot is
    /// fetched and validated before admission policy, LAN rendezvous, persisted
    /// binding state, and the engine revision move together.
    public func reconcileConnectivityRevision(
        _ hintedRevision: UInt64
    ) async -> CmxIrohLiveDiscoveryRefreshOutcome {
        guard lifecyclePhase == .active,
              let connectivityEngine,
              let admissionController,
              localBinding != nil else {
            return .failed(.endpointUnavailable)
        }
        while let refresh = registrationRefreshTask {
            await refresh.value
        }
        guard lifecyclePhase == .active,
              self.connectivityEngine === connectivityEngine else {
            return .failed(.endpointUnavailable)
        }
        if let installed = await connectivityEngine.snapshot().routeRevision,
           installed >= hintedRevision {
            return .refreshed
        }
        let revision = lifecycleRevision
        do {
            let discovery = try await discoverAuthoritatively()
            try requireCurrent(revision)
            guard let discoveredRevision = discovery.revision,
                  discoveredRevision >= hintedRevision else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            guard discovery.routeContractVersion
                    == CmxIrohRegistrationPayload.currentRouteContractVersion else {
                throw CmxIrohHostRuntimeError.routeContractMismatch
            }
            guard Set(discovery.relayFleet) == managedRelayURLs,
                  discovery.relayFleet.count == managedRelayURLs.count else {
                throw CmxIrohHostRuntimeError.relayFleetMismatch
            }
            guard let localBinding = self.localBinding else {
                throw CmxIrohHostRuntimeError.localBindingMissingFromDiscovery
            }
            guard let discovered = discovery.bindings.first(where: {
                $0.bindingID == localBinding.bindingID
            }) else {
                throw CmxIrohHostRuntimeError.localBindingMissingFromDiscovery
            }
            let endpointID = try await connectivityEngine.localEndpointIdentity()
            try validateLocalBinding(discovered, endpointID: endpointID)
            let attestation = try? await broker.issueEndpointAttestation(
                bindingID: discovered.bindingID
            )
            try requireCurrent(revision)
            let metadata = CmxIrohBrokerBindingMetadata(binding: discovered)
            await admissionController.update(
                keys: discovery.grantVerificationKeys,
                acceptor: grantPeer(for: metadata),
                pairingEnabled: discovered.pairingEnabled
            )
            self.localBinding = metadata
            endpointAttestation = attestation ?? endpointAttestation
            lanRendezvous = discovery.lanRendezvous
            await handleBinding(
                CmxIrohRegistrationResponse(
                    revision: discoveredRevision,
                    binding: discovered,
                    relay: .notRequested
                ),
                discovery,
                attestation
            )
            try requireCurrent(revision)
            await handleRoute(metadata, discovered.pathHints)
            try requireCurrent(revision)
            await connectivityEngine.didInstallRouteRevision(
                discoveredRevision,
                routes: discovery
            )
            scheduleLANPublication(
                binding: metadata,
                rendezvous: discovery.lanRendezvous,
                engine: connectivityEngine,
                revision: revision
            )
            scheduleRegistrationRenewal(
                binding: discovered,
                revision: revision
            )
            return .refreshed
        } catch {
            guard lifecyclePhase == .active,
                  lifecycleRevision == revision else {
                return .failed(.superseded)
            }
            if CmxIrohTrustBrokerClientError
                .preservesVerifiedStateDuringRefresh(error) {
                return .failed(DiagnosticFailureKind.classify(error))
            }
            lifecyclePhase = .stopping
            lifecycleRevision &+= 1
            let failureRevision = lifecycleRevision
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: self.localBinding?.bindingID
            )
            await tearDownComponents(notify: true)
            if lifecyclePhase == .stopping,
               lifecycleRevision == failureRevision {
                lifecyclePhase = .failed
            }
            return .failed(DiagnosticFailureKind.classify(error))
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
              let connectivityEngine else { return [] }
        return (try? await connectivityEngine.localDirectAddresses()) ?? []
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
        let bindingAuthorization = localBinding.flatMap { binding in
            try? CmxIrohBindingRequestAuthorization(
                bindingID: binding.bindingID,
                clientNamespace: binding.clientNamespace,
                identity: configuration.identity,
                endpointID: binding.endpointID
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
                bindingAuthorization: bindingAuthorization,
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
