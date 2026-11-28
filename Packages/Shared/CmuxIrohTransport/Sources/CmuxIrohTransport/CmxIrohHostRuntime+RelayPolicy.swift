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
              let connectivityEngine,
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

        relayActivationTask?.cancel()
        relayActivationTask = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        if profile.source == .managed, !profile.allowedRelayURLs.isEmpty {
            let refreshSchedule = CmxIrohRelayRefreshSchedule(
                role: .host,
                endpointIdentity: binding.endpointID
            )
            let coordinator = CmxIrohRelayCredentialCoordinator(
                supervisor: connectivityEngine,
                broker: broker,
                managedRelayURLs: replacementManagedURLs,
                selectedRelayURLs: profile.allowedRelayURLs,
                jitter: { now, refreshAfter in
                    refreshSchedule.deadline(now: now, refreshAfter: refreshAfter)
                },
                credentialDidInstall: { [handleRelayCredential] response in
                    await handleRelayCredential(response, binding)
                }
            )
            relayCoordinator = coordinator
            do {
                try await coordinator.activateManagedPolicy(
                    bindingID: binding.bindingID,
                    endpointIdentity: binding.endpointID,
                    profile: profile,
                    bootstrap: relayBootstrap
                )
            } catch {
                await coordinator.deactivate()
                if relayCoordinator === coordinator {
                    relayCoordinator = nil
                }
                throw error
            }
        } else {
            try await connectivityEngine.replaceRelayProfile(
                profile,
                expectedIdentity: binding.endpointID
            )
        }
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        currentEndpointRelayProfile = profile
        await admissionController?.updateManagedRelayURLs(replacementManagedURLs)
        try requireCurrent(revision)
    }
}
