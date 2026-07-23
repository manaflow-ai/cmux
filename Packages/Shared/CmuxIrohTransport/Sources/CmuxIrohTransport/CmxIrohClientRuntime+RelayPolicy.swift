extension CmxIrohClientRuntime {
    /// Installs a resolved relay policy without recreating the endpoint or sessions.
    public func replaceRelayPolicy(
        _ policy: CmxIrohEffectiveRelayPolicy
    ) async throws {
        let verifiedManagedURLs = policy.managedPolicy.map {
            Set($0.relays.map(\.url))
        } ?? managedRelayURLs
        try await replaceRelayProfile(
            policy.endpointRelayProfile,
            managedRelayURLs: verifiedManagedURLs,
            relayBootstrap: policy.relayBootstrap
        )
    }

    /// Installs an endpoint relay profile against the current verified managed fleet.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile
    ) async throws {
        try await replaceRelayProfile(
            profile,
            managedRelayURLs: managedRelayURLs,
            relayBootstrap: nil
        )
    }

    private func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        managedRelayURLs replacementManagedURLs: Set<String>,
        relayBootstrap: CmxIrohRelayTokenResponse?
    ) async throws {
        guard lifecyclePhase == .active, let binding = localBinding else {
            throw CmxIrohClientRuntimeError.inactive
        }
        guard (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
            replacementManagedURLs.count
        ),
        profile.source == .custom
            || profile.allowedRelayURLs.isSubset(of: replacementManagedURLs) else {
            throw CmxIrohClientRuntimeError.relayFleetMismatch
        }
        let revision = lifecycleRevision
        try await supervisor.replaceRelayProfile(
            profile,
            expectedIdentity: binding.endpointID
        )
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        endpointRelayProfile = profile
        let expectation = try CmxIrohLocalBindingExpectation(
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            platform: binding.platform,
            endpointID: binding.endpointID,
            identityGeneration: binding.identityGeneration,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities
        )
        let offlinePolicy = try offlinePolicyCache.map { cache in
            let offlineExpectation = try CmxIrohClientOfflinePolicyExpectation(
                accountID: configuration.accountID,
                localBindingExpectation: expectation,
                managedRelayURLs: replacementManagedURLs
            )
            return try CmxIrohClientOfflinePolicyContext(
                cache: cache,
                expectation: offlineExpectation,
                localBinding: binding
            )
        }
        let provider: CmxIrohRegistryContextProvider
        if let registryContextProvider {
            await registryContextProvider.updatePolicy(
                localBindingExpectation: expectation,
                managedRelayURLs: replacementManagedURLs,
                allowedRouteRelayURLs: profile.allowedRelayURLs,
                offlinePolicy: offlinePolicy
            )
            provider = registryContextProvider
        } else {
            provider = CmxIrohRegistryContextProvider(
                supervisor: supervisor,
                broker: broker,
                localBindingExpectation: expectation,
                managedRelayURLs: replacementManagedURLs,
                allowedRouteRelayURLs: profile.allowedRelayURLs,
                networkPathSnapshot: networkPathSnapshot,
                offlinePolicy: offlinePolicy,
                lanFallback: lanFallback,
                customPrivateFallback: customPrivateFallback,
                now: now
            )
            registryContextProvider = provider
        }
        await contextRouter.install(provider)
        try requireCurrent(revision)

        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        guard profile.source == .managed,
              !profile.allowedRelayURLs.isEmpty else { return }
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: replacementManagedURLs,
            selectedRelayURLs: profile.allowedRelayURLs,
            automaticRefreshEnabled: automaticRelayCredentialRefreshEnabled,
            credentialDidInstall: { [handleRelayCredential] response in
                await handleRelayCredential(response, binding)
            }
        )
        relayCoordinator = coordinator
        do {
            try await coordinator.activate(
                bindingID: binding.bindingID,
                endpointIdentity: binding.endpointID,
                bootstrap: relayBootstrap
            )
        } catch {
            // The verified allowlist is already live; direct paths remain usable
            // while the coordinator retries a managed credential refresh.
        }
    }
}
