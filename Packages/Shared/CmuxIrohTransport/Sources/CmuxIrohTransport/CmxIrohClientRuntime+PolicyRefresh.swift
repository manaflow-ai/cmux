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

    func scheduleRelayActivation(
        binding: CmxIrohBrokerBinding,
        revision: UInt64
    ) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let relayCoordinator else { return }
        relayActivationTask?.cancel()
        let bootstrap = configuration.cachedRelayCredential
        relayActivationTask = Task { [weak self] in
            guard let self else { return }
            await self.activateRelay(
                relayCoordinator,
                binding: binding,
                bootstrap: bootstrap,
                revision: revision
            )
        }
    }

    private func activateRelay(
        _ relayCoordinator: CmxIrohRelayCredentialCoordinator,
        binding: CmxIrohBrokerBinding,
        bootstrap: CmxIrohRelayTokenResponse?,
        revision: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              self.relayCoordinator === relayCoordinator else { return }
        do {
            try await relayCoordinator.activate(
                bindingID: binding.bindingID,
                endpointIdentity: binding.endpointID,
                bootstrap: bootstrap
            )
        } catch {
            // Direct paths stay usable while the coordinator owns retry.
        }
    }

    func scheduleRelayForegroundRefresh(revision: UInt64) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let relayCoordinator else { return }
        relayForegroundRefreshTask?.cancel()
        relayForegroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRelayAfterForeground(
                relayCoordinator,
                revision: revision
            )
        }
    }

    private func refreshRelayAfterForeground(
        _ relayCoordinator: CmxIrohRelayCredentialCoordinator,
        revision: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              self.relayCoordinator === relayCoordinator else { return }
        try? await relayCoordinator.refreshIfNeeded()
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
            let endpointID = try await connectivityEngine.localEndpointIdentity()
            guard !Task.isCancelled,
                  registrationRefreshTaskID == refreshID else {
                throw CancellationError()
            }
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision
            )
            guard !Task.isCancelled,
                  registrationRefreshTaskID == refreshID else {
                throw CancellationError()
            }
            let bindingChanged =
                policy.binding.bindingID != previousBinding.bindingID
            guard !bindingChanged
                || registrationRefreshAllowsBindingReplacement else {
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
                registrationRefreshAllowsBindingReplacement = false
                if let routeRevision = discovery.revision {
                    await connectivityEngine.didInstallRouteRevision(routeRevision)
                }
                liveDiscoveryGeneration &+= 1
                if bindingChanged {
                    scheduleRelayActivation(
                        binding: policy.binding,
                        revision: revision
                    )
                }
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
