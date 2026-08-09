public import CMUXMobileCore
public import Foundation

extension CmxIrohClientRuntime {
    func resolvePolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        prefetchedDiscovery: CmxIrohDiscoveryResponse? = nil,
        brokerPreparationComplete: Bool = false
    ) async throws -> ResolvedPolicy {
        if !brokerPreparationComplete {
            try await preparePolicyResolution(revision: revision)
        }
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
        // Without a managed relay fleet (policy unavailable or direct-only)
        // there is no relay bootstrap to cache offline; activation proceeds
        // with direct paths instead of failing the expectation's fleet check.
        let offlineExpectation: CmxIrohClientOfflinePolicyExpectation? =
            try offlinePolicyCache.flatMap { _ in
                guard !managedRelayURLs.isEmpty else { return nil }
                return try CmxIrohClientOfflinePolicyExpectation(
                    accountID: configuration.accountID,
                    localBindingExpectation: expectation,
                    managedRelayURLs: managedRelayURLs
                )
            }

        // The supervisor snapshot and the live endpoint address are separate
        // actor reads. Re-verify identity before every cached or online policy
        // path so an endpoint replacement cannot inherit the old tuple.
        let address = try await connectivityEngine.endpointAddress()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }

        // A revision is what orders this read-only snapshot against the signed
        // registration refresh that follows activation. Older brokers may
        // return discovery without one; keep that response off the fast path
        // and fall back to the full registration flow instead of stranding an
        // otherwise valid cached installation.
        var prefetchedDiscoveryRejectedCachedBinding = false
        if let cachedBinding = configuration.cachedBinding,
           let prefetchedDiscovery,
           prefetchedDiscovery.revision != nil {
            guard prefetchedDiscovery.routeContractVersion
                    == CmxIrohRegistrationPayload.currentRouteContractVersion else {
                throw CmxIrohClientRuntimeError.routeContractMismatch
            }
            try validateRelayFleet(prefetchedDiscovery.relayFleet)
            authoritativeDiscovery = prefetchedDiscovery
            let localMatches = prefetchedDiscovery.bindings.filter(expectation.matches)
            if localMatches.count == 1,
               let discovered = localMatches.first,
               CmxIrohBrokerBindingMetadata(binding: discovered) == cachedBinding {
                return ResolvedPolicy(
                    registration: nil,
                    discovery: prefetchedDiscovery,
                    binding: discovered,
                    expectation: expectation,
                    offlineExpectation: offlineExpectation,
                    cachedTargetBindings: [],
                    cachedLANRendezvous: nil
                )
            }
            prefetchedDiscoveryRejectedCachedBinding = true
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
                guard !prefetchedDiscoveryRejectedCachedBinding,
                      Self.recoversWithCachedPolicy(error),
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
            if let embedded = registration?.discovery,
               registration?.embeddedDiscoveryComplete == true {
                guard let snapshotRevision = embedded.revision,
                      let registrationRevision = registration?.revision,
                      snapshotRevision >= registrationRevision,
                      snapshotRevision >= (authoritativeDiscovery?.revision ?? 0) else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                let localMatches = embedded.bindings.filter(expectation.matches)
                if embedded.bindings.count
                    == CmxIrohDiscoveryPage.legacyBindingLimit
                    || localMatches.count != 1 {
                    discovery = try await discoverAuthoritatively(
                        minimumRevision: registrationRevision
                    )
                } else {
                    authoritativeDiscovery = embedded
                    discovery = embedded
                }
            } else {
                discovery = try await discoverAuthoritatively(
                    minimumRevision: registration?.revision
                )
            }
        } catch {
            guard let registration,
                  Self.recoversWithCachedPolicy(error),
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

    func preparePolicyResolution(revision: UInt64) async throws {
        try await pendingRevocations.revokePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            using: broker
        )
        try requireCurrent(revision)
        try await broker.preflight(operation: .discovery)
        try requireCurrent(revision)
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

    func prefetchAuthoritativeDiscovery() async throws -> CmxIrohDiscoveryResponse {
        try await CmxAuthoritativeDiscoveryResolver(
            broker: broker
        ).resolve(cached: nil)
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
                retrySchedule: .foregroundClient,
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
