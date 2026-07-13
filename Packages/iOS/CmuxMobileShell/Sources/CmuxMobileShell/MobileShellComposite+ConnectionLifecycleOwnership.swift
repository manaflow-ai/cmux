import Foundation

struct MobileConnectionLifecycleTaskOwnership {
    var activeUsesCachedReconnect = false
    var activeReconnectFence: SynchronousGenerationBoundary?
    var activeReconnectProgress: StoredMacReconnectProgress?
    var primaryRetiredTask: Task<Void, Never>?
    var primaryRetiredGeneration: UInt64 = 0
    var cachedRetiredTask: Task<Void, Never>?
    var cachedRetiredGeneration: UInt64 = 0
}

@MainActor
extension MobileShellComposite {
    /// One boundary for explicit user intent to supersede automatic reconnect.
    func supersedeAutomaticReconnectOwnership(clearPairingState: Bool) {
        if connectionLifecycle.isRecovering || connectionLifecycle.hasStoredMacReconnectDemand {
            resetConnectionLifecycle()
        }
        connectionLifecycleReconnectPendingAfterRetirement = false
        guard clearPairingState else { return }
        invalidatePairingAttempt()
        clearPairingError()
    }

    func requestConnectionLifecycleRecovery(
        _ trigger: MobileConnectionLifecycleTrigger
    ) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if trigger == .eventStreamLost {
            scheduleWorkspaceListRefreshFromEvent()
        }
        let effect = connectionLifecycle.request(
            trigger,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date()),
            reconnectStackUserID: identityProvider?.currentUserID
        )
        applyConnectionLifecycleEffect(effect)
    }

    func resetConnectionLifecycle() {
        let canceledKind = connectionLifecycle.activeEpisode?.kind
        let canceledStreamRepair = canceledKind == .streamRepair
        let canceledOperation = connectionLifecycleTask
        let canceledCachedReconnect = connectionLifecycleTaskOwnership.activeUsesCachedReconnect
        connectionLifecycle.reset()
        resumeCompletedConnectionLifecycleRequests()
        connectionLifecycleStreamRepairListenerID = nil
        connectionLifecycleReconnectPendingAfterRetirement = false
        invalidateStoredMacReconnectAttempt()
        connectionLifecycleTask = nil
        connectionLifecycleTaskOwnership.activeUsesCachedReconnect = false
        if canceledKind == .reconnect {
            if canceledCachedReconnect {
                retireCachedConnectionLifecycleTask(canceledOperation)
            } else {
                retireConnectionLifecycleTask(canceledOperation)
            }
        } else {
            canceledOperation?.cancel()
        }
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleDeadlineTask = nil
        reconcileMacConnectionStatusAfterLifecycleReset(
            canceledStreamRepair: canceledStreamRepair
        )
    }

    func restartStoredMacReconnectAfterScopeChange() {
        guard isSignedIn,
              connectionState != .connected,
              pairedMacStore != nil else { return }
        guard connectionLifecycleTaskOwnership.primaryRetiredTask == nil,
              connectionLifecycleTaskOwnership.cachedRetiredTask == nil else {
            connectionLifecycleReconnectPendingAfterRetirement = true
            return
        }
        let request = connectionLifecycle.requestStoredMacReconnect(
            stackUserID: identityProvider?.currentUserID,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date())
        )
        applyConnectionLifecycleEffect(request.effect)
    }

    func completeStreamRepairLifecycleEpisodeIfNeeded() {
        guard let episode = connectionLifecycle.activeEpisode,
              episode.kind == .streamRepair else { return }
        finishConnectionLifecycleEpisode(id: episode.id)
    }

    func completeStreamRepairLifecycleEpisodeIfReplacementIsHealthy(listenerID: UUID?) {
        guard let listenerID,
              listenerID == connectionLifecycleStreamRepairListenerID,
              let episode = connectionLifecycle.activeEpisode,
              episode.kind == .streamRepair else { return }
        finishConnectionLifecycleEpisode(id: episode.id)
    }

    func failConnectionLifecycleEpisodeIfNeeded() {
        guard let episode = connectionLifecycle.activeEpisode else { return }
        finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
    }

    func connectionLifecycleHealth(at now: Date) -> MobileConnectionLifecycleHealthSnapshot {
        let lastEvent = lastTerminalEventAt ?? now
        return MobileConnectionLifecycleHealthSnapshot(
            connected: connectionState == .connected,
            hasClient: remoteClient != nil,
            hasListener: terminalEventListenerTask != nil,
            eventStreamFresh: now.timeIntervalSince(lastEvent) < Self.renderGridLivenessSilenceThreshold,
            canReconnectPersistedMac: pairedMacStore != nil
        )
    }

    func makeStoredMacReconnectOperation(
        stackUserID: String?,
        usesCachedReconnect: Bool
    ) async -> StoredMacReconnectOperation? {
        guard let pairedMacStore,
              isSignedIn else {
            return nil
        }
        startObservingNetworkPathChanges()
        storedMacReconnectGeneration &+= 1
        let generation = storedMacReconnectGeneration
        storedMacReconnectTargetDeviceID = nil
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let cachedMacs = pairedMacsForIdentityMatching
        storedMacReconnectTargetDeviceID = cachedMacs.first(where: {
            $0.isActive && !Self.reconnectHostPortRoutes(
                $0.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            ).isEmpty
        })?.macDeviceID ?? cachedMacs.first(where: {
            !Self.reconnectHostPortRoutes(
                $0.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            ).isEmpty
        })?.macDeviceID
        guard let scope = await currentScopeSnapshot(userID: stackUserID),
              generation == storedMacReconnectGeneration else {
            return nil
        }
        let scopedKey = pairedMacScopeKey(scope)
        var pendingForgottenIDs = forgottenMacIntentDeviceIDsByScope[scopedKey] ?? []
        var forgottenScopeKeys = [scopedKey]
        if scope.teamID != nil {
            let userWideKey = pairedMacScopeKey(userWideScope(from: scope))
            pendingForgottenIDs.formUnion(
                forgottenMacIntentDeviceIDsByScope[userWideKey] ?? []
            )
            forgottenScopeKeys.append(userWideKey)
        }
        let fence = SynchronousGenerationBoundary()
        let fenceGeneration = fence.generation
        let progress = StoredMacReconnectProgress()
        connectionLifecycleTaskOwnership.activeReconnectFence?.invalidate()
        connectionLifecycleTaskOwnership.activeReconnectFence = fence
        connectionLifecycleTaskOwnership.activeReconnectProgress = progress
        return StoredMacReconnectOperation(
            runtime: runtime,
            store: pairedMacStore,
            forgottenStore: forgottenMacStore,
            scope: scope,
            generation: generation,
            fence: fence,
            fenceGeneration: fenceGeneration,
            progress: progress,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate,
            deviceRegistry: deviceRegistry,
            supportedKinds: supportedKinds,
            prefersNonLoopbackRoutes: Self.prefersNonLoopbackRoutes,
            cachedMacs: cachedMacs,
            pendingForgottenIDs: pendingForgottenIDs,
            forgottenScopeKeys: usesCachedReconnect ? [] : forgottenScopeKeys,
            loadsStoreSnapshot: !usesCachedReconnect,
            persistsPairedMac: !usesCachedReconnect
        )
    }

    func applyConnectionLifecycleEffect(
        _ effect: MobileConnectionLifecycleEffect?
    ) {
        guard case .start(let episode) = effect else { return }
        let usesCachedReconnect = episode.kind == .reconnect
            && connectionLifecycleTaskOwnership.primaryRetiredTask != nil
            && connectionLifecycleTaskOwnership.cachedRetiredTask == nil
            && episode.triggers.contains(.manualRetry)
        let hasRetiredReconnect = connectionLifecycleTaskOwnership.primaryRetiredTask != nil
            || connectionLifecycleTaskOwnership.cachedRetiredTask != nil
        if episode.kind == .reconnect,
           hasRetiredReconnect,
           !usesCachedReconnect {
            let hasCachedReconnectCandidate = pairedMacsForIdentityMatching.contains {
                !Self.reconnectHostPortRoutes(
                    $0.routes,
                    supportedKinds: runtime?.supportedRouteKinds ?? [],
                    preferNonLoopback: Self.prefersNonLoopbackRoutes
                ).isEmpty
            }
            if !episode.triggers.contains(.manualRetry) || !hasCachedReconnectCandidate {
                connectionLifecycleReconnectPendingAfterRetirement = true
            }
            finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
            return
        }
        connectionLifecycleTask?.cancel()
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleTaskOwnership.activeUsesCachedReconnect = usesCachedReconnect
        connectionLifecycleTask = Task { @MainActor [weak self] in
            guard self?.connectionLifecycle.ownsEpisode(episode.id) == true else { return }
            switch episode.kind {
            case .streamRepair:
                guard let self else { return }
                guard self.connectionState == .connected,
                      self.remoteClient != nil else {
                    self.finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
                    return
                }
                self.markMacConnectionReconnecting()
                self.resyncTerminalOutput(
                    reason: "lifecycle.\(episode.id)",
                    restartEventStream: true
                )
                self.connectionLifecycleStreamRepairListenerID = self.terminalEventListenerID
                let refreshesSecondaries = episode.triggers.contains(.networkPathChanged)
                    || episode.triggers.contains(.presenceRoutesChanged)
                    || episode.triggers.contains(.manualRetry)
                if self.multiMacAggregationEnabled, refreshesSecondaries {
                    self.scheduleSecondaryAggregation()
                }
                if self.terminalEventListenerTask == nil {
                    if self.runtime?.supportsServerPushEvents ?? true {
                        self.finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
                    } else {
                        self.markMacConnectionHealthy()
                        self.finishConnectionLifecycleEpisode(id: episode.id)
                    }
                }
            case .reconnect:
                guard let operation = await self?.makeStoredMacReconnectOperation(
                    stackUserID: episode.reconnectStackUserID,
                    usesCachedReconnect: usesCachedReconnect
                ) else {
                    self?.finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
                    return
                }
                let operationOutcome = await operation.run()
                guard let self,
                      !Task.isCancelled,
                      self.connectionLifecycle.ownsEpisode(episode.id) else { return }
                let outcome = self.applyStoredMacReconnectOperationOutcome(
                    operationOutcome,
                    generation: operation.generation
                )
                let cachedSnapshotWasUnavailable = usesCachedReconnect && outcome == .unavailable
                if cachedSnapshotWasUnavailable {
                    self.connectionLifecycleReconnectPendingAfterRetirement = true
                }
                self.finishConnectionLifecycleEpisode(
                    id: episode.id,
                    succeeded: outcome != .failed && !cachedSnapshotWasUnavailable
                )
                if cachedSnapshotWasUnavailable {
                    self.replayReconnectPendingAfterRetirementIfPossible()
                }
            }
            if self?.connectionLifecycle.ownsEpisode(episode.id) == true,
               episode.kind == .streamRepair {
                self?.connectionLifecycleTask = nil
            }
        }
        if episode.kind == .reconnect {
            let deadline = storedMacReconnectDeadline
            connectionLifecycleDeadlineTask = Task { @MainActor [weak self] in
                await deadline()
                guard !Task.isCancelled else { return }
                self?.expireStoredMacReconnectEpisode(id: episode.id)
            }
        } else {
            connectionLifecycleDeadlineTask = nil
        }
    }

    private func expireStoredMacReconnectEpisode(id: UInt64) {
        guard connectionLifecycle.ownsEpisode(id),
              connectionLifecycle.activeEpisode?.kind == .reconnect else { return }
        let operation = connectionLifecycleTask
        let usesCachedReconnect = connectionLifecycleTaskOwnership.activeUsesCachedReconnect
        connectionLifecycleTask = nil
        connectionLifecycleTaskOwnership.activeUsesCachedReconnect = false
        connectionLifecycleDeadlineTask = nil
        if usesCachedReconnect {
            retireCachedConnectionLifecycleTask(operation)
        } else {
            retireConnectionLifecycleTask(operation)
        }
        invalidateStoredMacReconnectAttempt()
        applyStoredMacReconnectDeadlineFailure()
        finishConnectionLifecycleEpisode(id: id, succeeded: false)
    }

    private func retireConnectionLifecycleTask(_ operation: Task<Void, Never>?) {
        guard let operation else { return }
        operation.cancel()
        guard connectionLifecycleTaskOwnership.primaryRetiredTask == nil else { return }
        connectionLifecycleTaskOwnership.primaryRetiredGeneration &+= 1
        let generation = connectionLifecycleTaskOwnership.primaryRetiredGeneration
        connectionLifecycleTaskOwnership.primaryRetiredTask = Task { @MainActor [weak self] in
            await operation.value
            guard let self,
                  self.connectionLifecycleTaskOwnership.primaryRetiredGeneration == generation else { return }
            self.connectionLifecycleTaskOwnership.primaryRetiredTask = nil
            if self.connectionLifecycleReconnectPendingAfterRetirement {
                self.replayReconnectPendingAfterRetirementIfPossible()
            } else if self.connectionLifecycleTaskOwnership.cachedRetiredTask == nil,
                      self.connectionState == .connected,
                      self.multiMacAggregationEnabled {
                self.scheduleSecondaryAggregation()
            }
        }
    }

    /// Tracks a canceled cached transport attempt separately from the primary
    /// cancellation-insensitive store operation that made the cached lane necessary.
    private func retireCachedConnectionLifecycleTask(_ operation: Task<Void, Never>?) {
        guard let operation else { return }
        operation.cancel()
        guard connectionLifecycleTaskOwnership.cachedRetiredTask == nil else { return }
        connectionLifecycleTaskOwnership.cachedRetiredGeneration &+= 1
        let generation = connectionLifecycleTaskOwnership.cachedRetiredGeneration
        connectionLifecycleTaskOwnership.cachedRetiredTask = Task { @MainActor [weak self] in
            await operation.value
            guard let self,
                  self.connectionLifecycleTaskOwnership.cachedRetiredGeneration == generation else { return }
            self.connectionLifecycleTaskOwnership.cachedRetiredTask = nil
            self.replayReconnectPendingAfterRetirementIfPossible()
        }
    }

    private func replayReconnectPendingAfterRetirementIfPossible() {
        guard connectionLifecycleTaskOwnership.primaryRetiredTask == nil,
              connectionLifecycleTaskOwnership.cachedRetiredTask == nil,
              connectionLifecycleReconnectPendingAfterRetirement else { return }
        connectionLifecycleReconnectPendingAfterRetirement = false
        restartStoredMacReconnectAfterScopeChange()
    }

    func abandonRetiredConnectionLifecycleTasks() {
        connectionLifecycleTaskOwnership.primaryRetiredGeneration &+= 1
        connectionLifecycleTaskOwnership.primaryRetiredTask?.cancel()
        connectionLifecycleTaskOwnership.primaryRetiredTask = nil
        connectionLifecycleTaskOwnership.cachedRetiredGeneration &+= 1
        connectionLifecycleTaskOwnership.cachedRetiredTask?.cancel()
        connectionLifecycleTaskOwnership.cachedRetiredTask = nil
        connectionLifecycleReconnectPendingAfterRetirement = false
    }

    func finishConnectionLifecycleEpisode(id: UInt64, succeeded: Bool = true) {
        guard connectionLifecycle.ownsEpisode(id) else { return }
        connectionLifecycleTaskOwnership.activeReconnectFence = nil
        connectionLifecycleTaskOwnership.activeReconnectProgress = nil
        connectionLifecycleStreamRepairListenerID = nil
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleDeadlineTask = nil
        let recoveryWasFailed = connectionLifecycle.recoveryFailed
        let effect = connectionLifecycle.complete(
            id: id,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date()),
            succeeded: succeeded
        )
        captureConnectionRecoveryFailureIfNeeded(wasFailed: recoveryWasFailed)
        resumeCompletedConnectionLifecycleRequests()
        if connectionLifecycleTask != nil,
           connectionLifecycle.activeEpisode?.id != id {
            connectionLifecycleTask = nil
            connectionLifecycleTaskOwnership.activeUsesCachedReconnect = false
        }
        applyConnectionLifecycleEffect(effect)
    }

    func recordConnectionRecoveryFailureWithoutEpisode() {
        let recoveryWasFailed = connectionLifecycle.recoveryFailed
        connectionLifecycle.markRecoveryFailed()
        captureConnectionRecoveryFailureIfNeeded(wasFailed: recoveryWasFailed)
    }

    private func resumeCompletedConnectionLifecycleRequests() {
        for requestID in connectionLifecycle.drainCompletedRequestIDs() {
            connectionLifecycleRequestWaiters.removeValue(forKey: requestID)?.resume()
        }
    }
}
