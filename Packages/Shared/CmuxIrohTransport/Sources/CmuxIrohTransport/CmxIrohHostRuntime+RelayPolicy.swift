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
        let previousRelayURLs = currentEndpointRelayProfile?.allowedRelayURLs
            ?? configuration.endpointRelayProfile?.allowedRelayURLs
            ?? []

        try await connectivityEngine.replaceRelayProfile(
            profile,
            expectedIdentity: binding.endpointID
        )
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        currentEndpointRelayProfile = profile
        await admissionController?.updateManagedRelayURLs(replacementManagedURLs)
        try requireCurrent(revision)

        // A changed relay allowlist changes how this host is dialed, so the
        // registration must be republished. This is the recovery path for a
        // host that activated during a relay policy outage (zero relays,
        // direct-only route) and only regained a managed relay when a later
        // policy refresh succeeded: without a forced round here nothing owns
        // that republication, and the host stays unreachable for remote
        // clients until an unrelated network change fires (cmux#10873).
        // Unchanged reinstalls (every periodic refresh success re-applies the
        // effective policy) schedule nothing.
        if profile.allowedRelayURLs != previousRelayURLs {
            scheduleRegistrationRefresh(
                revision: revision,
                forcePublication: true
            )
        }
    }
}
