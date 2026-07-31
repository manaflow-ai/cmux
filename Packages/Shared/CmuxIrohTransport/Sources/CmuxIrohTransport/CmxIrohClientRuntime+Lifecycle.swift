public import Foundation

extension CmxIrohClientRuntime {
    func performSignOut(
        pendingRevocation: CmxIrohPendingRevocation?,
        revision: UInt64
    ) async -> CmxIrohClientSignOutPreparation {
        async let wasPersisted = Self.persist(pendingRevocation, to: pendingRevocations)
        async let networkTeardown: Void = tearDownNetwork(preserveBinding: true)
        let (persisted, _) = await (wasPersisted, networkTeardown)
        let preparation = CmxIrohClientSignOutPreparation(
            pendingRevocation: pendingRevocation,
            wasPersisted: persisted
        )

        guard lifecyclePhase == .signingOut,
              lifecycleRevision == revision else {
            signOutOperation = nil
            return preparation
        }
        guard persisted else {
            lifecyclePhase = .quarantined
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .quarantined,
                endpointID: nil,
                bindingID: pendingRevocation?.bindingID
            )
            signOutOperation = nil
            return preparation
        }

        try? await offlinePolicyCache?.deactivate()
        await handleLocalDeactivation()
        guard lifecyclePhase == .signingOut,
              lifecycleRevision == revision else {
            signOutOperation = nil
            return preparation
        }
        localBinding = nil
        lifecyclePhase = .inactive
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
        signOutOperation = nil
        return preparation
    }

    nonisolated static func persist(
        _ revocation: CmxIrohPendingRevocation?,
        to pendingRevocations: CmxIrohPendingRevocationOutbox
    ) async -> Bool {
        guard let revocation else { return true }
        do {
            try await pendingRevocations.enqueue(revocation)
            return true
        } catch {
            return false
        }
    }

    func tearDownNetwork(preserveBinding: Bool = false) async {
        foregroundActive = false
        relayActivationTask?.cancel()
        relayActivationTask = nil
        relayForegroundRefreshTask?.cancel()
        relayForegroundRefreshTask = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        registrationRefreshTaskID = nil
        registrationRefreshPending = false
        registrationRefreshEnabled = false
        registrationRefreshAllowsBindingReplacement = false
        foregroundMaintenanceTask?.cancel()
        foregroundMaintenanceTask = nil
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await contextRouter.clear()
        authoritativeDiscovery = nil
        if !preserveBinding { localBinding = nil }
        await connectivityEngine.stop()
    }

    func validateRelayFleet(_ fleet: [String]) throws {
        // Without a verified managed fleet (relay policy unavailable) there is
        // nothing to cross-check and no relay will be configured; activation
        // continues on direct paths instead of failing closed here.
        guard !managedRelayURLs.isEmpty else { return }
        guard fleet.count == managedRelayURLs.count,
              Set(fleet) == managedRelayURLs else {
            throw CmxIrohClientRuntimeError.relayFleetMismatch
        }
    }

    /// Applies sticky terminal authority evidence to every runtime entrypoint.
    ///
    /// Broker availability failures never enter this path. Invalid auth,
    /// malformed policy, missing/replaced local binding, and fleet/contract
    /// substitution close networking and remove the signed offline cache.
    func failClosedAfterTerminalPolicyError(
        previousBinding: CmxIrohBrokerBinding,
        expectedRevision: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == expectedRevision else {
            return
        }
        lifecyclePhase = .stopping
        lifecycleRevision &+= 1
        let failureRevision = lifecycleRevision
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .failed,
            endpointID: nil,
            bindingID: previousBinding.bindingID
        )
        await tearDownNetwork()
        guard lifecyclePhase == .stopping,
              lifecycleRevision == failureRevision else {
            return
        }
        try? await offlinePolicyCache?.deactivate()
        await handlePolicyInvalidation()
        if lifecyclePhase == .stopping,
           lifecycleRevision == failureRevision {
            lifecyclePhase = .failed
        }
    }

    func requireCurrent(_ revision: UInt64) throws {
        guard lifecyclePhase.ownsNetworkOperation,
              lifecycleRevision == revision else {
            throw CmxIrohClientRuntimeError.superseded
        }
    }

    static func cachedRelayConfigurations(
        configuration: CmxIrohClientRuntimeConfiguration,
        now: Date
    ) -> [CmxIrohRelayConfiguration] {
        guard let cached = configuration.cachedRelayCredential,
              cached.relayFleet.count == configuration.managedRelayURLs.count,
              Set(cached.relayFleet) == configuration.managedRelayURLs else {
            return []
        }
        return (try? cached.relayConfigurations(now: now)) ?? []
    }

    static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }
}
