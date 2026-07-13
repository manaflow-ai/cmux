import Foundation

@MainActor
extension MobileShellComposite {
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
        connectionLifecycle.reset()
        resumeCompletedConnectionLifecycleRequests()
        connectionLifecycleStreamRepairListenerID = nil
        connectionLifecycleScopeReconnectPendingAfterRetirement = false
        invalidateStoredMacReconnectAttempt()
        connectionLifecycleTask = nil
        if canceledKind == .reconnect {
            retireConnectionLifecycleTask(canceledOperation)
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
        guard connectionLifecycleRetiredTask == nil else {
            connectionLifecycleScopeReconnectPendingAfterRetirement = true
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

    func applyConnectionLifecycleEffect(
        _ effect: MobileConnectionLifecycleEffect?
    ) {
        guard case .start(let episode) = effect else { return }
        let usesCachedReconnect = episode.kind == .reconnect
            && connectionLifecycleRetiredTask != nil
            && episode.triggers.contains(.manualRetry)
        if episode.kind == .reconnect,
           connectionLifecycleRetiredTask != nil,
           !usesCachedReconnect {
            finishConnectionLifecycleEpisode(id: episode.id)
            return
        }
        connectionLifecycleTask?.cancel()
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleTask = Task { @MainActor [weak self] in
            guard let self, self.connectionLifecycle.ownsEpisode(episode.id) else { return }
            switch episode.kind {
            case .streamRepair:
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
                if self.multiMacAggregationEnabled {
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
                let outcome = usesCachedReconnect
                    ? await self.performCachedStoredMacReconnect()
                    : await self.performStoredMacReconnect(
                        stackUserID: episode.reconnectStackUserID
                    )
                guard !Task.isCancelled,
                      self.connectionLifecycle.ownsEpisode(episode.id) else { return }
                self.finishConnectionLifecycleEpisode(
                    id: episode.id,
                    succeeded: outcome != .failed
                )
            }
            if self.connectionLifecycle.ownsEpisode(episode.id), episode.kind == .streamRepair {
                self.connectionLifecycleTask = nil
            }
        }
        if episode.kind == .reconnect, !usesCachedReconnect {
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
        connectionLifecycleTask = nil
        connectionLifecycleDeadlineTask = nil
        retireConnectionLifecycleTask(operation)
        invalidateStoredMacReconnectAttempt()
        applyStoredMacReconnectDeadlineFailure()
        finishConnectionLifecycleEpisode(id: id, succeeded: false)
    }

    private func retireConnectionLifecycleTask(_ operation: Task<Void, Never>?) {
        guard let operation else { return }
        operation.cancel()
        guard connectionLifecycleRetiredTask == nil else { return }
        connectionLifecycleRetiredTaskGeneration &+= 1
        let generation = connectionLifecycleRetiredTaskGeneration
        connectionLifecycleRetiredTask = Task { @MainActor [weak self] in
            await operation.value
            guard let self,
                  self.connectionLifecycleRetiredTaskGeneration == generation else { return }
            self.connectionLifecycleRetiredTask = nil
            let reconnectLatestScope = self.connectionLifecycleScopeReconnectPendingAfterRetirement
            self.connectionLifecycleScopeReconnectPendingAfterRetirement = false
            if reconnectLatestScope {
                self.restartStoredMacReconnectAfterScopeChange()
            } else if self.connectionState == .connected, self.multiMacAggregationEnabled {
                self.scheduleSecondaryAggregation()
            }
        }
    }

    func finishConnectionLifecycleEpisode(id: UInt64, succeeded: Bool = true) {
        guard connectionLifecycle.ownsEpisode(id) else { return }
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
