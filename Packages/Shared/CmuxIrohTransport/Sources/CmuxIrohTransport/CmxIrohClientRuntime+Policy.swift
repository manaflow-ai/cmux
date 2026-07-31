public import CMUXMobileCore
public import Foundation

extension CmxIrohClientRuntime {
    func resolveCachedPolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64
    ) async throws -> ResolvedPolicy? {
        try await pendingRevocations.revokePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            using: broker
        )
        try requireCurrent(revision)
        let expectation = try localBindingExpectation(
            endpointID: expectedEndpointID
        )
        let offlineExpectation = try offlineExpectation(
            localBindingExpectation: expectation
        )
        guard let cached = try await offlineBootstrap(
            expectation: offlineExpectation,
            confirmedLocalBinding: nil
        ) else {
            return nil
        }
        try requireCurrent(revision)
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

    func resolvePolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        pendingRevocationsDrained: Bool = false
    ) async throws -> ResolvedPolicy {
        if !pendingRevocationsDrained {
            try await pendingRevocations.revokePending(
                accountID: configuration.accountID,
                beforeRegisteringTag: configuration.tag,
                using: broker
            )
            try requireCurrent(revision)
        }
        try await broker.preflight(operation: .discovery)
        try requireCurrent(revision)
        let address = try await connectivityEngine.endpointAddress()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: now())
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
        let directPorts = CmxIrohDirectPorts(
            localDirectAddresses: try await connectivityEngine.localDirectAddresses()
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
        let expectation = try localBindingExpectation(
            endpointID: expectedEndpointID
        )
        // Without a managed relay fleet (policy unavailable or direct-only)
        // there is no relay bootstrap to cache offline; activation proceeds
        // with direct paths instead of failing the expectation's fleet check.
        let offlineExpectation = try offlineExpectation(
            localBindingExpectation: expectation
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse?
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            if CmxIrohBrokerCooldown.directiveSeconds(for: error) != nil {
                // Registration backpressure blocks mutation, while a fresh
                // authenticated discovery can still confirm an existing tuple.
                registration = nil
            } else {
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
        }
        try requireCurrent(revision)
        if let registration, !expectation.matches(registration.binding) {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }
        let discovery: CmxIrohDiscoveryResponse
        do {
            discovery = try await discoverAuthoritatively()
        } catch {
            guard let registration,
                  Self.isConnectivity(error),
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
              let discovered = localMatches.first else {
            throw CmxIrohClientRuntimeError.localBindingMissingFromDiscovery
        }
        if let registration,
           registration.binding.bindingID != discovered.bindingID {
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

    private func localBindingExpectation(
        endpointID: CmxIrohPeerIdentity
    ) throws -> CmxIrohLocalBindingExpectation {
        try CmxIrohLocalBindingExpectation(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities
        )
    }

    private func offlineExpectation(
        localBindingExpectation: CmxIrohLocalBindingExpectation
    ) throws -> CmxIrohClientOfflinePolicyExpectation? {
        try offlinePolicyCache.flatMap { _ in
            guard !managedRelayURLs.isEmpty else { return nil }
            return try CmxIrohClientOfflinePolicyExpectation(
                accountID: configuration.accountID,
                localBindingExpectation: localBindingExpectation,
                managedRelayURLs: managedRelayURLs
            )
        }
    }

    func discoverAuthoritatively() async throws -> CmxIrohDiscoveryResponse {
        guard let authority = broker as? any CmxConnectivityAuthorityServing else {
            let discovery = try await broker.discover()
            authoritativeDiscovery = discovery
            return discovery
        }
        let knownRevision = authoritativeDiscovery?.revision
        let response = try await authority.syncConnectivity(
            knownRevision: knownRevision
        )
        if let snapshot = response.snapshot {
            authoritativeDiscovery = snapshot
            return snapshot
        }
        guard let authoritativeDiscovery,
              authoritativeDiscovery.revision == response.revision else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return authoritativeDiscovery
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
                localEndpointIdentity: { [connectivityEngine] in
                    try await connectivityEngine.localEndpointIdentity()
                },
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
        let replacesBinding = localBinding.map {
            $0.bindingID != policy.binding.bindingID
        } ?? false
        if replacesBinding {
            relayActivationTask?.cancel()
            relayActivationTask = nil
            relayForegroundRefreshTask?.cancel()
            relayForegroundRefreshTask = nil
            await relayCoordinator?.deactivate()
            relayCoordinator = nil
        }
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
                supervisor: connectivityEngine,
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
