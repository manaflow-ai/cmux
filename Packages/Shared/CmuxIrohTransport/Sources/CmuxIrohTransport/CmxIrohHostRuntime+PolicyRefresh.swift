import CMUXMobileCore
import Foundation

extension CmxIrohHostRuntime {
    func resolvePolicy(
        supervisor: CmxIrohEndpointSupervisor,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
    ) async throws -> ResolvedPolicy {
        try await pendingRevocations.revokePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            using: broker
        )
        try requireCurrent(revision)
        let endpoint = try await supervisor.activeEndpoint()
        let address = await endpoint.address()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: now())
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
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
        guard Set(discovery.relayFleet) == configuration.managedRelayURLs,
              discovery.relayFleet.count == configuration.managedRelayURLs.count else {
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
              Set(cached.relayFleet) == configuration.managedRelayURLs,
              cached.relayFleet.count == configuration.managedRelayURLs.count else {
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
              lifecycleRevision == revision,
              registrationRefreshTask == nil else { return }
        registrationRefreshTask = Task { [weak self] in
            await self?.refreshRegistration(revision: revision)
        }
    }

    func refreshRegistration(revision: UInt64) async {
        defer { registrationRefreshTask = nil }
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
            await publishLANPolicy(
                binding: policy.binding,
                rendezvous: policy.lanRendezvous,
                supervisor: supervisor
            )
            try requireCurrent(revision)
            guard let registration = policy.registration,
                  let discovery = policy.discovery else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await handleBinding(registration, discovery, policy.attestation)
        } catch is CancellationError {
            return
        } catch {
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
            // Broker availability cannot invalidate policy that this generation
            // already authenticated. The next network change can retry without a
            // local busy loop.
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
