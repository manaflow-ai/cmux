internal import CMUXMobileCore
internal import Foundation

extension CmxIrohClientRuntime {
    func startSupervisorObservation(revision: UInt64) async {
        supervisorEventTask?.cancel()
        let events = await supervisor.events()
        supervisorEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .networkChanged:
                    await self.handleSupervisorNetworkChange(revision: revision)
                case let .recovered(_, newGeneration):
                    await self.handleSupervisorRecovery(
                        revision: revision,
                        runtimeGeneration: newGeneration
                    )
                case .snapshot:
                    break
                }
            }
        }
    }

    func handleSupervisorRecovery(
        revision: UInt64,
        runtimeGeneration: UInt64
    ) async {
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        if lifecyclePhase == .active {
            await sessionPool.activate(runtimeGeneration: runtimeGeneration)
        }
        handleSupervisorNetworkChange(revision: revision)
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

    func scheduleRegistrationRefresh(revision: UInt64) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision else { return }
        guard registrationRefreshTask == nil else {
            registrationRefreshPending = true
            return
        }
        registrationRefreshPending = false
        let refreshID = UUID()
        registrationRefreshTaskID = refreshID
        registrationRefreshTask = Task { [weak self] in
            guard let self else { return .failed(.superseded) }
            return try await self.refreshRegistration(
                revision: revision,
                refreshID: refreshID
            )
        }
    }

    func refreshRegistration(
        revision: UInt64,
        refreshID: UUID
    ) async throws -> CmxIrohLiveDiscoveryRefreshOutcome {
        defer {
            if lifecycleRevision == revision,
               registrationRefreshTaskID == refreshID {
                registrationRefreshTask = nil
                registrationRefreshTaskID = nil
                if registrationRefreshEnabled,
                   registrationRefreshPending,
                   lifecyclePhase == .active {
                    scheduleRegistrationRefresh(revision: revision)
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
            let endpoint = try await supervisor.activeEndpoint()
            let endpointID = await endpoint.identity()
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision
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
            if let registration = policy.registration,
               let discovery = policy.discovery {
                let published = await handleBinding(registration, discovery)
                try requireCurrent(revision)
                guard published else { return .failed(.superseded) }
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
                .preservesVerifiedPolicyDuringRefresh(error) else {
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
