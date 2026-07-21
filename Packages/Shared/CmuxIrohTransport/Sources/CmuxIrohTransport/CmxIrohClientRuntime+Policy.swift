public import CMUXMobileCore
public import Foundation

extension CmxIrohClientRuntime {
    func resolvePolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64
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
            throw CmxIrohClientRuntimeError.invalidLocalBinding
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
            platform: .ios,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            directPorts: directPorts,
            now: now()
        )
        let expectation = try CmxIrohLocalBindingExpectation(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .ios,
            endpointID: expectedEndpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities
        )
        let offlineExpectation = try offlinePolicyCache.map { _ in
            try CmxIrohClientOfflinePolicyExpectation(
                accountID: configuration.accountID,
                localBindingExpectation: expectation,
                managedRelayURLs: managedRelayURLs
            )
        }
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            guard Self.isConnectivity(error),
                  let cached = try await offlineBootstrap(
                      expectation: offlineExpectation,
                      confirmedLocalBinding: nil
                  ) else { throw error }
            return ResolvedPolicy(
                registration: nil,
                discovery: nil,
                binding: cached.localBinding,
                expectation: expectation,
                offlineExpectation: offlineExpectation,
                cachedTargetBindings: cached.targetBindings,
                cachedLANRendezvous: cached.lanRendezvous
            )
        }
        try requireCurrent(revision)
        guard expectation.matches(registration.binding) else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }
        let discovery: CmxIrohDiscoveryResponse
        do {
            discovery = try await broker.discover()
        } catch {
            guard Self.isConnectivity(error),
                  let cached = try await offlineBootstrap(
                      expectation: offlineExpectation,
                      confirmedLocalBinding: registration.binding
                  ) else { throw error }
            return ResolvedPolicy(
                registration: registration,
                discovery: nil,
                binding: cached.localBinding,
                expectation: expectation,
                offlineExpectation: offlineExpectation,
                cachedTargetBindings: cached.targetBindings,
                cachedLANRendezvous: cached.lanRendezvous
            )
        }
        try requireCurrent(revision)
        guard discovery.routeContractVersion == payload.routeContractVersion else {
            throw CmxIrohClientRuntimeError.routeContractMismatch
        }
        try validateRelayFleet(discovery.relayFleet)
        let localMatches = discovery.bindings.filter(expectation.matches)
        guard localMatches.count == 1,
              let discovered = localMatches.first,
              discovered.bindingID == registration.binding.bindingID else {
            throw CmxIrohClientRuntimeError.localBindingMissingFromDiscovery
        }
        return ResolvedPolicy(
            registration: registration,
            discovery: discovery,
            binding: discovered,
            expectation: expectation,
            offlineExpectation: offlineExpectation,
            cachedTargetBindings: [],
            cachedLANRendezvous: nil
        )
    }

    func offlineBootstrap(
        expectation: CmxIrohClientOfflinePolicyExpectation?,
        confirmedLocalBinding: CmxIrohBrokerBinding?
    ) async throws -> CmxIrohClientOfflineBootstrap? {
        guard let offlinePolicyCache, let expectation else { return nil }
        return try await offlinePolicyCache.loadBootstrap(
            for: expectation,
            confirmedLocalBinding: confirmedLocalBinding,
            now: now()
        )
    }

    func install(
        policy: ResolvedPolicy,
        revision: UInt64,
        startRelays: Bool
    ) async throws {
        try requireCurrent(revision)
        let offlinePolicy = try policy.offlineExpectation.map { expectation in
            guard let offlinePolicyCache else {
                throw CmxIrohClientOfflinePolicyCacheError.policyMismatch
            }
            return try CmxIrohClientOfflinePolicyContext(
                cache: offlinePolicyCache,
                expectation: expectation,
                localBinding: policy.binding
            )
        }
        let provider: CmxIrohRegistryContextProvider
        if let registryContextProvider {
            await registryContextProvider.updatePolicy(
                localBindingExpectation: policy.expectation,
                managedRelayURLs: managedRelayURLs,
                allowedRouteRelayURLs: endpointRelayProfile.allowedRelayURLs,
                offlinePolicy: offlinePolicy,
                verifiedDiscovery: policy.discovery
            )
            provider = registryContextProvider
        } else {
            provider = CmxIrohRegistryContextProvider(
                supervisor: supervisor,
                broker: broker,
                localBindingExpectation: policy.expectation,
                managedRelayURLs: managedRelayURLs,
                allowedRouteRelayURLs: endpointRelayProfile.allowedRelayURLs,
                networkPathSnapshot: networkPathSnapshot,
                offlinePolicy: offlinePolicy,
                lanFallback: lanFallback,
                customPrivateFallback: customPrivateFallback,
                verifiedDiscovery: policy.discovery,
                now: now
            )
            registryContextProvider = provider
        }
        await contextRouter.install(provider)
        localBinding = policy.binding

        guard endpointRelayProfile.source == .managed,
              !endpointRelayProfile.allowedRelayURLs.isEmpty else {
            await relayCoordinator?.deactivate()
            relayCoordinator = nil
            return
        }

        let coordinator: CmxIrohRelayCredentialCoordinator
        if let relayCoordinator {
            coordinator = relayCoordinator
        } else {
            coordinator = CmxIrohRelayCredentialCoordinator(
                supervisor: supervisor,
                broker: broker,
                managedRelayURLs: managedRelayURLs,
                selectedRelayURLs: endpointRelayProfile.allowedRelayURLs,
                automaticRefreshEnabled: automaticRelayCredentialRefreshEnabled,
                credentialDidInstall: { [handleRelayCredential] response in
                    await handleRelayCredential(response, policy.binding)
                }
            )
            relayCoordinator = coordinator
        }

        let bootstrap = startRelays ? configuration.cachedRelayCredential : nil
        if startRelays || bootstrap != nil {
            let requiresRelayReadiness = !protocolConfiguration
                .allowsNATTraversalAfterAdmission
            do {
                try await coordinator.activate(
                    bindingID: policy.binding.bindingID,
                    endpointIdentity: policy.binding.endpointID,
                    bootstrap: bootstrap,
                    waitForInitialCredential: requiresRelayReadiness
                )
            } catch {
                if requiresRelayReadiness { throw error }
                // Registration remains authoritative; direct paths remain usable.
            }
        }
    }
}
