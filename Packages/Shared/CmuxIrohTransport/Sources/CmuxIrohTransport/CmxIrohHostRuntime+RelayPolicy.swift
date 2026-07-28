extension CmxIrohHostRuntime {
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
        guard lifecyclePhase == .active,
              let supervisor,
              let binding = localBinding else {
            throw CmxIrohHostRuntimeError.inactive
        }
        guard (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
            replacementManagedURLs.count
        ),
        profile.source == .custom
            || profile.allowedRelayURLs.isSubset(of: replacementManagedURLs) else {
            throw CmxIrohHostRuntimeError.relayFleetMismatch
        }
        let revision = lifecycleRevision
        try await supervisor.replaceRelayProfile(
            profile,
            expectedIdentity: binding.endpointID
        )
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        currentEndpointRelayProfile = profile
        await admissionController?.updateManagedRelayURLs(replacementManagedURLs)
        try requireCurrent(revision)

        relayActivationTask?.cancel()
        relayActivationTask = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        guard profile.source == .managed,
              !profile.allowedRelayURLs.isEmpty else { return }
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: replacementManagedURLs,
            selectedRelayURLs: profile.allowedRelayURLs,
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
