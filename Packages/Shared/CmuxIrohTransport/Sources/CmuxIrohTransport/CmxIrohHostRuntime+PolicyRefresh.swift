import CMUXMobileCore
import Foundation

extension CmxIrohHostRuntime {
    func resolveInitialPolicy(
        engine: CmxConnectivityEngine,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64
    ) async throws -> ResolvedPolicy {
        var failureCount = 0
        while true {
            try requireCurrent(revision)
            do {
                return try await resolvePolicyAfterAuthenticatedRegistration(
                    engine: engine,
                    expectedEndpointID: expectedEndpointID,
                    revision: revision,
                    allowCachedFallback: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as CmxIrohPostRegistrationRevocationFailure {
                throw failure.underlying
            } catch {
                try requireCurrent(revision)
                guard CmxIrohTrustBrokerClientError
                    .retriesInitialActivation(error) else {
                    throw error
                }
                let delay = registrationRetrySchedule.delay(
                    failureCount: failureCount,
                    retryAfterSeconds: (error as? any CmxRetryAfterProviding)?
                        .retryAfterSeconds,
                    jitterUnitInterval: registrationRetryJitter()
                )
                failureCount = min(failureCount + 1, 20)
                let deadline = registrationClock.now().addingTimeInterval(delay)
                // This bounded broker backoff is the intended delay; the
                // lifecycle-owned start task cancels the injected clock sleep.
                try await registrationClock.sleep(until: deadline)
            }
        }
    }

    func resolvePolicy(
        engine: CmxConnectivityEngine,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
    ) async throws -> ResolvedPolicy {
        do {
            return try await resolvePolicyAfterAuthenticatedRegistration(
                engine: engine,
                expectedEndpointID: expectedEndpointID,
                revision: revision,
                allowCachedFallback: allowCachedFallback
            )
        } catch let failure as CmxIrohPostRegistrationRevocationFailure {
            throw failure.underlying
        }
    }

    private func reconcilePendingAfterRegistration(
        activeBindingID: String
    ) async throws -> Bool {
        try await pendingRevocations.reconcilePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            activeBindingID: activeBindingID,
            using: broker
        )
    }

    private func resolvePolicyAfterAuthenticatedRegistration(
        engine: CmxConnectivityEngine,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
    ) async throws -> ResolvedPolicy {
        // Cached fallback may return before a registration payload is built.
        // Verify the live endpoint first so a replaced driver cannot inherit
        // the prior generation's broker tuple.
        let liveAddress = try await engine.endpointAddress()
        guard liveAddress.identity == expectedEndpointID else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        // Discovery follows registration in one trust round. Honor a restored
        // discovery floor first so activation cannot spend a registration call
        // that is guaranteed to stop at the next broker operation.
        do {
            try await broker.preflight(operation: .discovery)
        } catch {
            return try cachedPolicy(
                after: error,
                expectedEndpointID: expectedEndpointID,
                confirmedBinding: nil,
                relayBootstrap: nil,
                allowFallback: allowCachedFallback
            )
        }
        try requireCurrent(revision)
        let payload = try await registrationPayload(
            engine: engine,
            expectedEndpointID: expectedEndpointID
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            return try cachedPolicy(
                after: error,
                expectedEndpointID: expectedEndpointID,
                confirmedBinding: nil,
                relayBootstrap: nil,
                allowFallback: allowCachedFallback
            )
        }
        try requireCurrent(revision)
        try validateLocalBinding(registration.binding, endpointID: expectedEndpointID)
        let revokedPendingBinding: Bool
        do {
            revokedPendingBinding = try await reconcilePendingAfterRegistration(
                activeBindingID: registration.binding.bindingID
            )
        } catch {
            throw CmxIrohPostRegistrationRevocationFailure(underlying: error)
        }
        try requireCurrent(revision)
        let discovery: CmxIrohDiscoveryResponse
        do {
            if !revokedPendingBinding,
               let embedded = registration.discovery,
               registration.embeddedDiscoveryComplete {
                guard let snapshotRevision = embedded.revision,
                      let registrationRevision = registration.revision,
                      snapshotRevision == registrationRevision,
                      snapshotRevision >= (authoritativeDiscovery?.revision ?? 0) else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                if embedded.bindings.contains(where: {
                    $0.bindingID == registration.binding.bindingID
                }) {
                    authoritativeDiscovery = embedded
                    discovery = embedded
                } else {
                    // Legacy registration responses embed only the first
                    // discovery page. Once an account has enough dev builds,
                    // the binding just registered can land on a later page.
                    // Resolve the complete snapshot instead of misclassifying
                    // pagination as a replaced local identity.
                    discovery = try await discoverAuthoritatively(
                        minimumRevision: registration.revision
                    )
                }
            } else {
                discovery = try await discoverAuthoritatively(
                    minimumRevision: registration.revision
                )
            }
        } catch {
            return try cachedPolicy(
                after: error,
                expectedEndpointID: expectedEndpointID,
                confirmedBinding: registration.binding,
                relayBootstrap: nil,
                allowFallback: allowCachedFallback
            )
        }
        try requireCurrent(revision)
        guard discovery.routeContractVersion == payload.routeContractVersion else {
            throw CmxIrohHostRuntimeError.routeContractMismatch
        }
        // A missing verified relay policy disables relays but must not disable
        // direct registration and discovery. Once policy is available, retain
        // the exact fleet cross-check before admitting relay routes.
        guard managedRelayURLs.isEmpty || (
            Set(discovery.relayFleet) == managedRelayURLs
                && discovery.relayFleet.count == managedRelayURLs.count
        ) else {
            throw CmxIrohHostRuntimeError.relayFleetMismatch
        }
        guard let discovered = discovery.bindings.first(where: {
            $0.bindingID == registration.binding.bindingID
        }) else {
            throw CmxIrohHostRuntimeError.localBindingMissingFromDiscovery
        }
        try validateLocalBinding(discovered, endpointID: expectedEndpointID)
        let attestation = try? await broker.issueEndpointAttestation(
            bindingID: discovered.bindingID
        )
        try requireCurrent(revision)
        lastRegistrationRefreshState = CmxIrohRegistrationPublicationState(
            payload: payload,
            now: now()
        )
        return ResolvedPolicy(
            registration: registration,
            discovery: discovery,
            binding: CmxIrohBrokerBindingMetadata(binding: discovered),
            pairingEnabled: discovered.pairingEnabled,
            grantVerificationKeys: discovery.grantVerificationKeys,
            attestation: attestation,
            relayBootstrap: configuration.cachedRelayCredential,
            lanRendezvous: discovery.lanRendezvous,
            routePathHints: discovered.pathHints,
            registrationRetryAfterSeconds: nil
        )
    }

    func registrationPublicationState(
        engine: CmxConnectivityEngine,
        expectedEndpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRegistrationPublicationState {
        let timestamp = now()
        return CmxIrohRegistrationPublicationState(
            payload: try await registrationPayload(
                engine: engine,
                expectedEndpointID: expectedEndpointID,
                timestamp: timestamp
            ),
            now: timestamp
        )
    }

    func registrationPayload(
        engine: CmxConnectivityEngine,
        expectedEndpointID: CmxIrohPeerIdentity,
        timestamp: Date? = nil
    ) async throws -> CmxIrohRegistrationPayload {
        let address = try await engine.endpointAddress()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let payloadTime = timestamp ?? now()
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: payloadTime)
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
        return try CmxIrohRegistrationPayload(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            clientNamespace: configuration.clientNamespace,
            tag: configuration.tag,
            platform: .mac,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: configuration.pairingEnabled,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            directPorts: CmxIrohDirectPorts(
                localDirectAddresses: try await engine.localDirectAddresses()
            ),
            now: payloadTime
        )
    }

    func discoverAuthoritatively(
        minimumRevision: UInt64? = nil
    ) async throws -> CmxIrohDiscoveryResponse {
        let discovery = try await CmxAuthoritativeDiscoveryResolver(
            broker: broker
        ).resolve(
            cached: authoritativeDiscovery,
            minimumRevision: minimumRevision
        )
        authoritativeDiscovery = discovery
        return discovery
    }

    /// Returns a start policy from the persisted last-good broker policy when
    /// it still cryptographically verifies for this exact account, identity,
    /// endpoint, and host settings. Any mismatch is a silent cache miss so
    /// activation falls back to the blocking authenticated resolve.
    func validatedCachedStartPolicy(
        expectedEndpointID: CmxIrohPeerIdentity
    ) -> ResolvedPolicy? {
        guard let cached = configuration.cachedHostPolicy else { return nil }
        do {
            try validateCachedPolicy(cached, endpointID: expectedEndpointID)
        } catch {
            return nil
        }
        return ResolvedPolicy(
            registration: nil,
            discovery: nil,
            binding: cached.binding,
            pairingEnabled: cached.pairingEnabled,
            grantVerificationKeys: cached.grantVerificationKeys,
            attestation: cached.endpointAttestation,
            relayBootstrap: configuration.cachedRelayCredential,
            lanRendezvous: cached.lanRendezvous,
            routePathHints: [],
            registrationRetryAfterSeconds: nil
        )
    }

    func cachedPolicy(
        after error: any Error,
        expectedEndpointID: CmxIrohPeerIdentity,
        confirmedBinding: CmxIrohBrokerBinding?,
        relayBootstrap: CmxIrohRelayTokenResponse?,
        allowFallback: Bool
    ) throws -> ResolvedPolicy {
        if let confirmedBinding, let localBinding,
           CmxIrohBrokerBindingMetadata(binding: confirmedBinding) != localBinding {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        guard allowFallback,
              CmxIrohTrustBrokerClientError
                .preservesVerifiedStateDuringRefresh(error),
              let cached = configuration.cachedHostPolicy else {
            throw error
        }
        try validateCachedPolicy(cached, endpointID: expectedEndpointID)
        if let confirmedBinding {
            guard CmxIrohBrokerBindingMetadata(binding: confirmedBinding) == cached.binding,
                  confirmedBinding.pairingEnabled == cached.pairingEnabled,
                  confirmedBinding.capabilities.count == cached.capabilities.count,
                  Set(confirmedBinding.capabilities) == Set(cached.capabilities) else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
        }
        return ResolvedPolicy(
            registration: nil,
            discovery: nil,
            binding: cached.binding,
            pairingEnabled: cached.pairingEnabled,
            grantVerificationKeys: cached.grantVerificationKeys,
            attestation: cached.endpointAttestation,
            relayBootstrap: relayBootstrap ?? configuration.cachedRelayCredential,
            lanRendezvous: cached.lanRendezvous,
            routePathHints: [],
            registrationRetryAfterSeconds: (
                error as? any CmxRetryAfterProviding
            )?.retryAfterSeconds
        )
    }

    func validateLocalBinding(
        _ binding: CmxIrohBrokerBinding,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        guard binding.deviceID == configuration.deviceID,
              binding.appInstanceID == configuration.appInstanceID,
              binding.clientNamespace == configuration.clientNamespace,
              binding.tag == configuration.tag,
              binding.platform == .mac,
              binding.endpointID == endpointID,
              binding.identityGeneration == configuration.identity.generation,
              binding.pairingEnabled == configuration.pairingEnabled,
              Set(binding.capabilities) == Set(configuration.capabilities),
              binding.capabilities.count == configuration.capabilities.count else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
    }

    func validateCachedPolicy(
        _ policy: CmxIrohCachedHostPolicy,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        let binding = policy.binding
        guard binding.deviceID == configuration.deviceID,
              binding.appInstanceID == configuration.appInstanceID,
              binding.clientNamespace == configuration.clientNamespace,
              binding.tag == configuration.tag,
              binding.platform == .mac,
              binding.endpointID == endpointID,
              binding.identityGeneration == configuration.identity.generation,
              policy.pairingEnabled == configuration.pairingEnabled,
              policy.capabilities.count == configuration.capabilities.count,
              Set(policy.capabilities) == Set(configuration.capabilities),
              policy.endpointAttestation.grantVerificationKeys
                  == policy.grantVerificationKeys else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let validationTime = now()
        let claims = try CmxIrohGrantVerifier().verifyEndpointAttestation(
            policy.endpointAttestation.attestation,
            keys: policy.grantVerificationKeys,
            expected: endpointExpectation(for: binding),
            now: validationTime
        )
        guard let envelopeExpiry = CmxIrohISO8601Date.parse(policy.endpointAttestation.expiresAt),
              Self.seconds(envelopeExpiry) == claims.expiresAt,
              envelopeExpiry > validationTime else {
            throw CmxIrohHostPolicyCacheError.invalidAttestationEnvelope
        }
    }

    func cachedRelayConfigurations() -> [CmxIrohRelayConfiguration] {
        guard let cached = configuration.cachedRelayCredential,
              Set(cached.relayFleet) == managedRelayURLs,
              cached.relayFleet.count == managedRelayURLs.count else {
            return []
        }
        return (try? cached.relayConfigurations(now: now())) ?? []
    }

    func startConnectivityObservation(
        engine: CmxConnectivityEngine,
        revision: UInt64
    ) async {
        connectivityEventTask?.cancel()
        let events = await engine.networkChanges()
        connectivityEventTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.handleConnectivityNetworkChange(revision: revision)
            }
        }
    }

    func handleConnectivityNetworkChange(revision: UInt64) async {
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        await handleLANRefresh()
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        guard registrationRefreshEnabled else {
            registrationRefreshPending = true
            return
        }
        scheduleRegistrationRefresh(revision: revision)
    }

    func scheduleRegistrationRefresh(
        revision: UInt64,
        forcePublication: Bool = false
    ) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        guard registrationRefreshTask == nil else {
            // Address watchers may publish again while an earlier broker round
            // is suspended. Preserve that newer snapshot as a dirty bit so the
            // running round cannot overwrite the final usable relay address.
            registrationRefreshPending = true
            registrationRefreshPendingForcesPublication =
                registrationRefreshPendingForcesPublication || forcePublication
            return
        }
        registrationRefreshPending = false
        registrationRefreshPendingForcesPublication = false
        registrationRefreshTask = Task { [weak self] in
            await self?.refreshRegistration(
                revision: revision,
                forcePublication: forcePublication
            )
        }
    }

    func scheduleRegistrationRenewal(
        binding: CmxIrohBrokerBinding,
        revision: UInt64
    ) {
        registrationRenewalTask?.cancel()
        registrationRenewalTask = nil
        guard lifecyclePhase.ownsNetworkOperation,
              lifecycleRevision == revision,
              let deadline = Self.registrationRenewalDeadline(
                  binding: binding,
                  now: registrationClock.now()
              ) else { return }
        registrationRenewalTask = Task { [weak self] in
            await self?.runRegistrationRenewal(
                revision: revision,
                firstDeadline: deadline
            )
        }
    }

    private func runRegistrationRenewal(
        revision: UInt64,
        firstDeadline: Date
    ) async {
        do {
            try await registrationClock.sleep(until: firstDeadline)
        } catch {
            return
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              !Task.isCancelled else { return }
        scheduleRegistrationRefresh(
            revision: revision,
            forcePublication: true
        )
        await registrationRefreshTask?.value
    }

    func scheduleRegistrationRetry(
        revision: UInt64,
        retryAfterSeconds: Int?
    ) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        let delay = registrationRetrySchedule.delay(
            failureCount: registrationRefreshFailureCount,
            retryAfterSeconds: retryAfterSeconds,
            jitterUnitInterval: registrationRetryJitter()
        )
        registrationRefreshFailureCount = min(
            registrationRefreshFailureCount + 1,
            20
        )
        registrationRenewalTask?.cancel()
        let deadline = registrationClock.now().addingTimeInterval(delay)
        registrationRenewalTask = Task { [weak self] in
            await self?.runRegistrationRenewal(
                revision: revision,
                firstDeadline: deadline
            )
        }
    }

    static func registrationRenewalDeadline(
        binding: CmxIrohBrokerBinding,
        now: Date
    ) -> Date? {
        // Clients accept the binding's signed direct ports for private-path
        // synthesis only while `lastSeenAt` is younger than this same window.
        // Keep that broker lease fresh even when the endpoint has no public
        // path hints, otherwise an unchanged Mac silently becomes undialable.
        let bindingFreshnessExpiry = CmxIrohISO8601Date
            .parse(binding.lastSeenAt)?
            .addingTimeInterval(CmxIrohPathHint.maximumPrivateHintTTL)
        let expiries = ([bindingFreshnessExpiry] + binding.pathHints.map(\.expiresAt))
            .compactMap { $0 }
        return expiries.compactMap { expiry -> Date? in
            let remaining = expiry.timeIntervalSince(now)
            guard remaining > 0 else { return nil }
            let safetyWindow = min(15 * 60, max(30, remaining / 4))
            let deadline = expiry.addingTimeInterval(-safetyWindow)
            // A stale or near-expiry authority cannot safely arm an immediate
            // renewal: another unchanged success would otherwise spin.
            return deadline > now ? deadline : nil
        }.min()
    }

    func refreshRegistration(
        revision: UInt64,
        forcePublication: Bool
    ) async {
        var completedSuccessfully = false
        defer {
            if lifecycleRevision == revision {
                registrationRefreshTask = nil
                if completedSuccessfully,
                   registrationRefreshPending,
                   lifecyclePhase == .active {
                    let pendingForcesPublication =
                        registrationRefreshPendingForcesPublication
                    scheduleRegistrationRefresh(
                        revision: revision,
                        forcePublication: pendingForcesPublication
                    )
                }
            }
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let connectivityEngine,
              let admissionController,
              let previousBinding = localBinding else { return }
        do {
            let endpointID = try await connectivityEngine.localEndpointIdentity()
            if !forcePublication, !initialPublicationPending {
                let state = try await registrationPublicationState(
                    engine: connectivityEngine,
                    expectedEndpointID: endpointID
                )
                guard state.requiresPublication(
                    after: lastRegistrationRefreshState,
                    now: now()
                ) else {
                    completedSuccessfully = true
                    return
                }
            }
            let policy = try await resolvePolicy(
                engine: connectivityEngine,
                expectedEndpointID: endpointID,
                revision: revision,
                allowCachedFallback: false
            )
            if policy.binding.bindingID != previousBinding.bindingID {
                guard allowsReplacedBindingAdoption else {
                    throw CmxIrohHostRuntimeError.invalidLocalBinding
                }
                // A cache-first activation discovered its persisted binding
                // was replaced server-side. Adopt the authenticated result in
                // place, exactly as the blocking activation path would have.
                try await adoptReplacedBinding(policy: policy, revision: revision)
            }
            allowsReplacedBindingAdoption = false
            await admissionController.update(
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled
            )
            try requireCurrent(revision)
            localBinding = policy.binding
            if currentSnapshot.bindingID != policy.binding.bindingID {
                currentSnapshot = CmxIrohHostRuntimeSnapshot(
                    state: currentSnapshot.state,
                    endpointID: currentSnapshot.endpointID,
                    bindingID: policy.binding.bindingID
                )
            }
            endpointAttestation = policy.attestation ?? endpointAttestation
            lanRendezvous = policy.lanRendezvous
            guard let registration = policy.registration,
                  let discovery = policy.discovery else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            if initialPublicationPending {
                let ready = await initialPublicationReady(
                    engine: connectivityEngine
                )
                try requireCurrent(revision)
                guard ready else {
                    // The first publication of this lifecycle stays gated on
                    // a verified usable relay path; the authenticated
                    // reconcile above already applied admission policy,
                    // binding adoption, and renewal scheduling. The ready
                    // gate runs the publishing round once the relay works.
                    registrationRefreshFailureCount = 0
                    completedSuccessfully = true
                    scheduleRegistrationRenewal(
                        binding: registration.binding,
                        revision: revision
                    )
                    return
                }
            }
            await handleBinding(registration, discovery, policy.attestation)
            try requireCurrent(revision)
            await handleRoute(policy.binding, policy.routePathHints)
            try requireCurrent(revision)
            if let routeRevision = discovery.revision {
                await connectivityEngine.didInstallRouteRevision(
                    routeRevision,
                    routes: discovery
                )
            }
            scheduleLANPublication(
                binding: policy.binding,
                rendezvous: policy.lanRendezvous,
                engine: connectivityEngine,
                revision: revision
            )
            registrationRefreshFailureCount = 0
            initialPublicationPending = false
            completedSuccessfully = true
            scheduleRegistrationRenewal(
                binding: registration.binding,
                revision: revision
            )
        } catch is CancellationError {
            return
        } catch {
            guard lifecyclePhase == .active,
                  lifecycleRevision == revision else { return }
            guard CmxIrohTrustBrokerClientError
                .preservesVerifiedStateDuringRefresh(error) else {
                lifecyclePhase = .stopping
                lifecycleRevision &+= 1
                let failureRevision = lifecycleRevision
                currentSnapshot = CmxIrohHostRuntimeSnapshot(
                    state: .failed,
                    endpointID: nil,
                    bindingID: localBinding?.bindingID
                )
                await tearDownComponents(notify: true)
                if lifecyclePhase == .stopping,
                   lifecycleRevision == failureRevision {
                    lifecyclePhase = .failed
                }
                return
            }
            // One retry owner honors both bounded exponential backoff and the
            // broker's validated Retry-After floor. A later retry re-reads the
            // endpoint, so address changes observed during this failed round are
            // already included without an immediate duplicate broker request.
            registrationRefreshPending = false
            scheduleRegistrationRetry(
                revision: revision,
                retryAfterSeconds: (
                    error as? any CmxRetryAfterProviding
                )?.retryAfterSeconds
            )
        }
    }

    /// Rebinds binding-scoped components to an authenticated replacement
    /// binding. `CmxIrohAdmissionController.update` already propagates the new
    /// acceptor to online and offline admission; only the relay credential
    /// coordinator pins a binding ID at activation and must be recreated.
    private func adoptReplacedBinding(
        policy: ResolvedPolicy,
        revision: UInt64
    ) async throws {
        try requireCurrent(revision)
        guard let connectivityEngine else {
            throw CmxIrohHostRuntimeError.inactive
        }
        // The startup ready gate retains the superseded cached binding and
        // relay bootstrap it was armed with. Cancel and drain it before
        // rebinding so it can never activate the replacement coordinator with
        // the stale identity or install a stale relay credential; the deferred
        // first publication is re-armed onto the adopted binding below.
        if let staleReadyGate = initialPublicationTask {
            staleReadyGate.cancel()
            initialPublicationTask = nil
            await staleReadyGate.value
            try requireCurrent(revision)
        }
        try await rebindRelayCoordinator(
            policy: policy,
            engine: connectivityEngine,
            revision: revision
        )
        if initialPublicationPending {
            // The drained gate owned the relay-readiness wait for the deferred
            // first publication. Re-arm it bound to the adopted identity so
            // the endpoint still publishes once the relay becomes usable.
            scheduleInitialPublication(
                binding: policy.binding,
                endpointID: policy.binding.endpointID,
                bootstrap: policy.relayBootstrap,
                revision: revision
            )
        }
    }

    /// Deactivates the coordinator pinned to the replaced binding and, for a
    /// managed relay profile, activates a replacement pinned to the adopted
    /// binding.
    private func rebindRelayCoordinator(
        policy: ResolvedPolicy,
        engine: CmxConnectivityEngine,
        revision: UInt64
    ) async throws {
        guard let coordinator = relayCoordinator else { return }
        relayActivationTask?.cancel()
        relayActivationTask = nil
        await coordinator.deactivate()
        if relayCoordinator === coordinator {
            relayCoordinator = nil
        }
        try requireCurrent(revision)
        let binding = policy.binding
        guard let profile = currentEndpointRelayProfile,
              profile.source == .managed,
              !profile.allowedRelayURLs.isEmpty else { return }
        let replacement = CmxIrohRelayCredentialCoordinator(
            supervisor: engine,
            broker: broker,
            managedRelayURLs: managedRelayURLs,
            selectedRelayURLs: profile.allowedRelayURLs,
            credentialDidInstall: { [handleRelayCredential] response in
                await handleRelayCredential(response, binding)
            }
        )
        relayCoordinator = replacement
        do {
            try await replacement.activate(
                bindingID: binding.bindingID,
                endpointIdentity: binding.endpointID,
                bootstrap: policy.relayBootstrap
            )
        } catch {
            // The replacement coordinator owns bounded retry. An unavailable
            // relay credential must not fail the adopted live policy.
        }
        try requireCurrent(revision)
    }

    static func seconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            return nil
        }
        return Int64(value.rounded(.down))
    }
}
