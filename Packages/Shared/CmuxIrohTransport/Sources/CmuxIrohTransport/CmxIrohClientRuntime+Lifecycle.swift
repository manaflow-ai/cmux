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
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        registrationRefreshTaskID = nil
        registrationRefreshPending = false
        registrationRefreshEnabled = false
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await sessionPool.deactivate()
        await contextRouter.clear()
        if !preserveBinding { localBinding = nil }
        await supervisor.deactivate()
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

    /// Failures that may fall back to the verified offline policy cache.
    ///
    /// Connectivity has always qualified. An unauthorized rejection (401/403)
    /// qualifies too: it already survived the broker client's single
    /// force-refresh retry, so it is a session transition still settling or a
    /// server-side availability condition, and the cached bootstrap carries no
    /// authority the broker did not previously sign. Proceeding keeps LAN and
    /// cached-relay paths dialable while auth settles; a genuinely dead session
    /// stops the runtime through the auth coordinator's state clear.
    static func recoversWithCachedPolicy(_ error: any Error) -> Bool {
        if isConnectivity(error) { return true }
        guard case let .rejected(statusCode, _)? =
            error as? CmxIrohTrustBrokerClientError else { return false }
        return statusCode == 401 || statusCode == 403
    }
}
