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
}
