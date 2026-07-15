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
        registrationRefreshTask = Task { [weak self] in
            do {
                try await self?.refreshRegistration(revision: revision)
            } catch {
                // Terminal errors already revoke local policy and stop networking.
            }
        }
    }

    func refreshRegistration(revision: UInt64) async throws {
        defer {
            if lifecycleRevision == revision {
                registrationRefreshTask = nil
                if registrationRefreshEnabled,
                   registrationRefreshPending,
                   lifecyclePhase == .active {
                    scheduleRegistrationRefresh(revision: revision)
                }
            }
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let previousBinding = localBinding else { return }
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
                await handleBinding(registration, discovery)
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
            }
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
