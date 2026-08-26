internal import CMUXMobileCore
internal import Foundation

extension CmxIrohClientRuntime {
    func startSupervisorObservation(revision: UInt64) async {
        supervisorEventTask?.cancel()
        let events = await connectivityEngine.networkChanges()
        supervisorEventTask = Task { [weak self] in
            guard let self else { return }
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self.handleSupervisorNetworkChange(revision: revision)
            }
        }
    }

    func handleSupervisorNetworkChange(revision: UInt64) {
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        guard registrationRefreshEnabled else {
            registrationRefreshPending = true
            return
        }
        scheduleRegistrationRefresh(revision: revision)
    }

    func scheduleRegistrationRefresh(
        revision: UInt64,
        requiresDiscovery: Bool = false
    ) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        guard registrationRefreshTask == nil else {
            registrationRefreshPending = true
            registrationRefreshPendingRequiresDiscovery =
                registrationRefreshPendingRequiresDiscovery || requiresDiscovery
            return
        }
        registrationRefreshPending = false
        registrationRefreshPendingRequiresDiscovery = false
        let refreshID = UUID()
        registrationRefreshTaskID = refreshID
        registrationRefreshTask = Task { [weak self] in
            guard let self else { return .failed(.superseded) }
            return try await self.refreshRegistration(
                revision: revision,
                refreshID: refreshID,
                requiresDiscovery: requiresDiscovery
            )
        }
    }

    func refreshRegistration(
        revision: UInt64,
        refreshID: UUID,
        requiresDiscovery: Bool
    ) async throws -> CmxIrohLiveDiscoveryRefreshOutcome {
        defer {
            if lifecycleRevision == revision,
               registrationRefreshTaskID == refreshID {
                registrationRefreshTask = nil
                registrationRefreshTaskID = nil
                if registrationRefreshEnabled,
                   registrationRefreshPending,
                   lifecyclePhase == .active {
                    let pendingRequiresDiscovery =
                        registrationRefreshPendingRequiresDiscovery
                    scheduleRegistrationRefresh(
                        revision: revision,
                        requiresDiscovery: pendingRequiresDiscovery
                    )
                }
            }
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else {
            return .failed(.superseded)
        }
        guard let previousBinding = localBinding else {
            return .failed(.endpointUnavailable)
        }
        do {
            let endpointID = try await connectivityEngine.localEndpointIdentity()
            if !requiresDiscovery {
                let state = try await registrationRefreshState(
                    expectedEndpointID: endpointID
                )
                guard state.requiresPublication(
                    after: lastRegistrationRefreshState,
                    now: now()
                ) else { return .refreshed }
            }
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision,
                allowReadOnlyRegistrationRefresh: requiresDiscovery
            )
            guard policy.binding.bindingID == previousBinding.bindingID else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            try await install(policy: policy, revision: revision, startRelays: false)
            try requireCurrent(revision)
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let discovery = policy.discovery {
                let published = await handleBinding(policy.binding, discovery)
                try requireCurrent(revision)
                guard published else { return .failed(.superseded) }
                if let routeRevision = discovery.revision {
                    await connectivityEngine.didInstallRouteRevision(
                        routeRevision,
                        routes: discovery
                    )
                }
                liveDiscoveryGeneration &+= 1
                return .refreshed
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
                return .failed(.offline)
            }
            return .failed(.policyUnavailable)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard lifecyclePhase == .active,
                  lifecycleRevision == revision else {
                throw error
            }
            guard !CmxIrohTrustBrokerClientError
                .preservesVerifiedStateDuringRefresh(error) else {
                // Keep the last exact verified binding while broker availability
                // prevents a refresh.
                return .failed(DiagnosticFailureKind.classify(error))
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
                throw error
            }
            try? await offlinePolicyCache?.deactivate()
            await handlePolicyInvalidation()
            if lifecyclePhase == .stopping,
               lifecycleRevision == failureRevision {
                lifecyclePhase = .failed
            }
            throw error
        }
    }
}
