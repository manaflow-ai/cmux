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
            managedRelayURLs: verifiedManagedURLs
        )
    }

    /// Installs an endpoint relay profile against the current verified managed fleet.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile
    ) async throws {
        try await replaceRelayProfile(
            profile,
            managedRelayURLs: managedRelayURLs
        )
    }

    private func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        managedRelayURLs replacementManagedURLs: Set<String>
    ) async throws {
        // A debug-only forced relay pins every profile installation, so a
        // broker policy refresh cannot displace the test relay mid-run.
        var profile = profile
        if let debugOverride = CmxIrohDebugRelayOverride.activeProfile() {
            profile = debugOverride
        }
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

        try await connectivityEngine.replaceRelayProfile(
            profile,
            expectedIdentity: binding.endpointID
        )
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        endpointRelayProfile = profile
        let expectation = try CmxIrohLocalBindingExpectation(
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            clientNamespace: binding.clientNamespace,
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
                localEndpointIdentity: { [connectivityEngine] in
                    try await connectivityEngine.localEndpointIdentity()
                },
                broker: broker,
                localBindingExpectation: expectation,
                managedRelayURLs: replacementManagedURLs,
                allowedRouteRelayURLs: profile.allowedRelayURLs,
                networkPathSnapshot: networkPathSnapshot,
                offlinePolicy: offlinePolicy,
                lanFallback: lanFallback,
                customPrivateFallback: customPrivateFallback,
                diagnostics: diagnosticLog,
                now: now
            )
            registryContextProvider = provider
        }
        await contextRouter.install(provider)
        try requireCurrent(revision)
    }
}
