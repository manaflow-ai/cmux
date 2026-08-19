import Foundation

extension CmxIrohClientRuntime {
    func performSignOut(
        pendingRevocation: CmxIrohPendingRevocation?,
        bindingAuthorization: CmxIrohBindingRequestAuthorization?,
        revision: UInt64
    ) async -> CmxIrohClientSignOutPreparation {
        await performSignOutFlow(
            pendingRevocation: pendingRevocation,
            bindingAuthorization: bindingAuthorization,
            revision: revision,
            tearDownNetwork: {
                await self.tearDownNetwork(preserveBinding: true)
            },
            deactivateLocalState: { [offlinePolicyCache, handleLocalDeactivation] in
                try? await offlinePolicyCache?.deactivate()
                await handleLocalDeactivation()
            }
        )
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
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
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
    /// Only transport availability qualifies. Authorization rejections fail
    /// closed even when an older policy was previously verified: the broker
    /// has explicitly withdrawn this session's authority after the client's
    /// exactly-once credential recovery.
    static func recoversWithCachedPolicy(_ error: any Error) -> Bool {
        isConnectivity(error)
    }
}
