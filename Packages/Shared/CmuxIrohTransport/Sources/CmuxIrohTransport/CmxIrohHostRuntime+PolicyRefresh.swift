import CMUXMobileCore
import Foundation

extension CmxIrohHostRuntime {
    func resolveInitialPolicy(
        supervisor: CmxIrohEndpointSupervisor,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64
    ) async throws -> ResolvedPolicy {
        try await revokePendingBeforeRegistration()
        try requireCurrent(revision)
        var failureCount = 0
        while true {
            try requireCurrent(revision)
            do {
                return try await resolvePolicyAfterPendingRevocations(
                    supervisor: supervisor,
                    expectedEndpointID: expectedEndpointID,
                    revision: revision,
                    allowCachedFallback: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try requireCurrent(revision)
                guard CmxIrohTrustBrokerClientError
                    .retriesInitialActivation(error) else {
                    throw error
                }
                let delay = registrationRetrySchedule.delay(
                    failureCount: failureCount,
                    retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
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
        supervisor: CmxIrohEndpointSupervisor,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
    ) async throws -> ResolvedPolicy {
        try await revokePendingBeforeRegistration()
        try requireCurrent(revision)
        return try await resolvePolicyAfterPendingRevocations(
            supervisor: supervisor,
            expectedEndpointID: expectedEndpointID,
            revision: revision,
            allowCachedFallback: allowCachedFallback
        )
    }

    private func revokePendingBeforeRegistration() async throws {
        try await pendingRevocations.revokePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            using: broker
        )
    }

    private func resolvePolicyAfterPendingRevocations(
        supervisor: CmxIrohEndpointSupervisor,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
    ) async throws -> ResolvedPolicy {
        let endpoint = try await supervisor.activeEndpoint()
        let address = await endpoint.address()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: now())
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
        let directPorts = CmxIrohDirectPorts(
            localDirectAddresses: await endpoint.localDirectAddresses()
        )
        let payload = try CmxIrohRegistrationPayload(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .mac,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: configuration.pairingEnabled,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            directPorts: directPorts,
            now: now()
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
        let discovery: CmxIrohDiscoveryResponse
        do {
            discovery = try await broker.discover()
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
        guard Set(discovery.relayFleet) == managedRelayURLs,
              discovery.relayFleet.count == managedRelayURLs.count else {
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
        return ResolvedPolicy(
            registration: registration,
            discovery: discovery,
            binding: CmxIrohBrokerBindingMetadata(binding: discovered),
            pairingEnabled: discovered.pairingEnabled,
            grantVerificationKeys: discovery.grantVerificationKeys,
            attestation: attestation,
            relayBootstrap: configuration.cachedRelayCredential,
            lanRendezvous: discovery.lanRendezvous
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
        guard allowFallback, Self.isConnectivityFailure(error),
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
            lanRendezvous: cached.lanRendezvous
        )
    }

    func validateLocalBinding(
        _ binding: CmxIrohBrokerBinding,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        guard binding.deviceID == configuration.deviceID,
              binding.appInstanceID == configuration.appInstanceID,
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

    func startSupervisorObservation(
        supervisor: CmxIrohEndpointSupervisor,
        revision: UInt64
    ) async {
        supervisorEventTask?.cancel()
        let events = await supervisor.events()
        supervisorEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .networkChanged, .recovered:
                    await self?.handleSupervisorNetworkChange(revision: revision)
                case .snapshot:
                    break
                }
            }
        }
    }

    func handleSupervisorNetworkChange(revision: UInt64) async {
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

    func scheduleRegistrationRefresh(revision: UInt64) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        guard registrationRefreshTask == nil else {
            // Address watchers may publish again while an earlier broker round
            // is suspended. Preserve that newer snapshot as a dirty bit so the
            // running round cannot overwrite the final usable relay address.
            registrationRefreshPending = true
            return
        }
        registrationRefreshPending = false
        registrationRefreshTask = Task { [weak self] in
            await self?.refreshRegistration(revision: revision)
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
        scheduleRegistrationRefresh(revision: revision)
        await registrationRefreshTask?.value
    }

    private func scheduleRegistrationRetry(
        revision: UInt64,
        error: any Error
    ) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        let delay = registrationRetrySchedule.delay(
            failureCount: registrationRefreshFailureCount,
            retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
                .retryAfterSeconds,
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
        guard let expiry = binding.pathHints.compactMap(\.expiresAt).min(),
              expiry > now else { return nil }
        let remaining = expiry.timeIntervalSince(now)
        let safetyWindow = min(15 * 60, max(30, remaining / 4))
        return max(now, expiry.addingTimeInterval(-safetyWindow))
    }

    func refreshRegistration(revision: UInt64) async {
        var completedSuccessfully = false
        defer {
            if lifecycleRevision == revision {
                registrationRefreshTask = nil
                if completedSuccessfully,
                   registrationRefreshPending,
                   lifecyclePhase == .active {
                    scheduleRegistrationRefresh(revision: revision)
                }
            }
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let supervisor,
              let admissionController,
              let previousBinding = localBinding else { return }
        do {
            let endpoint = try await supervisor.activeEndpoint()
            let endpointID = await endpoint.identity()
            let policy = try await resolvePolicy(
                supervisor: supervisor,
                expectedEndpointID: endpointID,
                revision: revision,
                allowCachedFallback: false
            )
            guard policy.binding.bindingID == previousBinding.bindingID else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await admissionController.update(
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled
            )
            try requireCurrent(revision)
            localBinding = policy.binding
            endpointAttestation = policy.attestation ?? endpointAttestation
            lanRendezvous = policy.lanRendezvous
            guard let registration = policy.registration,
                  let discovery = policy.discovery else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await handleBinding(registration, discovery, policy.attestation)
            try requireCurrent(revision)
            scheduleLANPublication(
                binding: policy.binding,
                rendezvous: policy.lanRendezvous,
                supervisor: supervisor,
                revision: revision
            )
            registrationRefreshFailureCount = 0
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
                .preservesVerifiedPolicyDuringRefresh(error) else {
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
            scheduleRegistrationRetry(revision: revision, error: error)
        }
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
