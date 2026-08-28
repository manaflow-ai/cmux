public import Foundation

extension CmxIrohClientRuntime {
    func performSignOut(
        pendingRevocation: CmxIrohPendingRevocation?,
        bindingAuthorization: CmxIrohBindingRequestAuthorization?,
        revision: UInt64
    ) async -> CmxIrohClientSignOutPreparation {
        async let wasPersisted = Self.persist(pendingRevocation, to: pendingRevocations)
        async let networkTeardown: Void = tearDownNetwork(preserveBinding: true)
        let (persisted, _) = await (wasPersisted, networkTeardown)
        let preparation = CmxIrohClientSignOutPreparation(
            pendingRevocation: pendingRevocation,
            wasPersisted: persisted,
            bindingAuthorization: bindingAuthorization
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
        lastRegistrationRefreshState = nil
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
        registrationRefreshPendingRequiresDiscovery = false
        registrationRefreshEnabled = false
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        await registryContextProvider?.cancelCacheFirstRefresh()
        await contextRouter.clear()
        authoritativeDiscovery = nil
        if !preserveBinding {
            localBinding = nil
            lastRegistrationRefreshState = nil
        }
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

    func requireCurrent(_ revision: UInt64) throws {
        guard lifecyclePhase.ownsNetworkOperation,
              lifecycleRevision == revision else {
            throw CmxIrohClientRuntimeError.superseded
        }
    }

    static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }

    /// Failures that may fall back to the verified offline policy cache.
    ///
    /// Only transport availability qualifies. Authorization rejections fail
    /// closed even when an older policy was previously verified: the broker
    /// has explicitly withdrawn this session's authority after the client's
    /// exactly-once credential recovery.
    static func recoversWithCachedPolicy(_ error: any Error) -> Bool {
        isConnectivity(error)
    }
}
