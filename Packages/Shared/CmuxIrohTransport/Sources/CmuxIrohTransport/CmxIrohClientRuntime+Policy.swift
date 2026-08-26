public import CMUXMobileCore
public import Foundation

extension CmxIrohClientRuntime {
    func resolvePolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        prefetchedDiscovery: CmxIrohDiscoveryResponse? = nil,
        brokerPreparationComplete: Bool = false,
        allowReadOnlyRegistrationRefresh: Bool = false
    ) async throws -> ResolvedPolicy {
        if !brokerPreparationComplete {
            try await preparePolicyResolution(revision: revision)
        }
        let expectation = try CmxIrohLocalBindingExpectation(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            clientNamespace: configuration.clientNamespace,
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

        // Cached discovery may return before a registration payload is built.
        // Verify the live endpoint address first so a replaced driver cannot
        // inherit the prior generation's broker tuple.
        let liveAddress = try await connectivityEngine.endpointAddress()
        guard liveAddress.identity == expectedEndpointID else {
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

        let payload = try await registrationPayload(
            expectedEndpointID: expectedEndpointID
        )
        let refreshState = Self.registrationRefreshState(
            payload: payload,
            now: now()
        )
        if allowReadOnlyRegistrationRefresh,
           shouldUseReadOnlyRegistrationRefresh(refreshState, at: now()) {
            do {
                return try await readOnlyResolvedPolicy(
                    expectation: expectation,
                    offlineExpectation: offlineExpectation
                )
            } catch CmxIrohClientRuntimeError.localBindingMissingFromDiscovery {
                // The server no longer has this binding. Fall through to a
                // signed mutation so the client self-heals instead of staying
                // read-only forever.
            }
        }
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse?
        var registrationFailure: (any Error)?
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            if CmxIrohBrokerCooldown.directiveSeconds(for: error) != nil {
                // Registration backpressure blocks mutation, while a fresh
                // authenticated discovery can still confirm an existing tuple.
                registration = nil
                registrationFailure = error
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
        if registration == nil,
           !(await broker.hasBindingAuthorization()) {
            // No registration response means this broker instance did not get
            // a chance to install fresh proof. Do not drain revocations or
            // issue namespaced discovery requests without persisted proof.
            throw registrationFailure
                ?? CmxIrohTrustBrokerClientError.invalidAuthentication
        }
        if registration != nil {
            lastRegistrationRefreshState = refreshState
        }
        let revokedPendingBinding: Bool
        let activeBindingID: String?
        if let registration {
            activeBindingID = registration.binding.bindingID
        } else {
            activeBindingID = await broker.bindingAuthorizationID()
        }
        guard let activeBindingID else {
            throw CmxIrohTrustBrokerClientError.invalidAuthentication
        }
        revokedPendingBinding = try await pendingRevocations.reconcilePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            activeBindingID: activeBindingID,
            using: broker
        )
        try requireCurrent(revision)
        let discovery: CmxIrohDiscoveryResponse
        do {
            if !revokedPendingBinding,
               let embedded = registration?.discovery,
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

    func readOnlyResolvedPolicy(
        expectation: CmxIrohLocalBindingExpectation,
        offlineExpectation: CmxIrohClientOfflinePolicyExpectation?
    ) async throws -> ResolvedPolicy {
        let discovery = try await discoverAuthoritatively()
        guard discovery.routeContractVersion
                == CmxIrohRegistrationPayload.currentRouteContractVersion else {
            throw CmxIrohClientRuntimeError.routeContractMismatch
        }
        try validateRelayFleet(discovery.relayFleet)
        let localMatches = discovery.bindings.filter(expectation.matches)
        guard localMatches.count == 1,
              let discovered = localMatches.first else {
            throw CmxIrohClientRuntimeError.localBindingMissingFromDiscovery
        }
        return ResolvedPolicy(
            registration: nil,
            discovery: discovery,
            binding: discovered,
            expectation: expectation,
            offlineExpectation: offlineExpectation,
            cachedTargetBindings: [],
            cachedLANRendezvous: nil
        )
    }

    func shouldUseReadOnlyRegistrationRefresh(
        _ state: CmxIrohRegistrationPublicationState,
        at now: Date
    ) -> Bool {
        !state.requiresPublication(after: lastRegistrationRefreshState, now: now)
    }

    func registrationRefreshState(
        expectedEndpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRegistrationPublicationState {
        let timestamp = now()
        return CmxIrohRegistrationPublicationState(
            payload: try await registrationPayload(
                expectedEndpointID: expectedEndpointID,
                timestamp: timestamp
            ),
            now: timestamp
        )
    }

    func registrationPayload(
        expectedEndpointID: CmxIrohPeerIdentity,
        timestamp: Date? = nil
    ) async throws -> CmxIrohRegistrationPayload {
        // The supervisor snapshot and live endpoint address are separate actor
        // reads. Re-verify identity before comparing or publishing the tuple.
        let address = try await connectivityEngine.endpointAddress()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
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
            platform: .ios,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            directPorts: CmxIrohDirectPorts(
                localDirectAddresses: try await connectivityEngine.localDirectAddresses()
            ),
            now: payloadTime
        )
    }

    static func registrationRefreshState(
        payload: CmxIrohRegistrationPayload,
        now: Date
    ) -> CmxIrohRegistrationPublicationState {
        CmxIrohRegistrationPublicationState(payload: payload, now: now)
    }

    func preparePolicyResolution(revision: UInt64) async throws {
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
        revision: UInt64
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
                diagnostics: diagnosticLog,
                verifiedDiscovery: policy.discovery,
                now: now
            )
            registryContextProvider = provider
        }
        await contextRouter.install(provider)
        localBinding = policy.binding
    }
}
