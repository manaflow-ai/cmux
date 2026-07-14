import Foundation

@MainActor
extension MobileShellComposite {
    func invalidateStoredMacReconnectAttempt() {
        invalidateDeferredCachedReconnectPersistence()
        connectionLifecycleTaskOwnership.activeReconnectFence?.invalidate()
        connectionLifecycleTaskOwnership.activeReconnectFence = nil
        connectionLifecycleTaskOwnership.activeReconnectProgress = nil
        storedMacReconnectGeneration &+= 1
        storedMacReconnectTargetDeviceID = nil
    }

    func replayReconnectPendingAfterRetirementIfPossible() {
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
        connectionLifecycleTaskOwnership.clearRetiredReconnectDemand()
        invalidateDeferredCachedReconnectPersistence()
        connectionLifecycleReconnectPendingAfterRetirement = false
    }

    func invalidateDeferredCachedReconnectPersistence(
        forgetting macDeviceIDs: Set<String> = []
    ) {
        if let pending = connectionLifecycleTaskOwnership.pendingCachedReconnectPersistence {
            pending.progress.markForgotten(macDeviceIDs)
            pending.fence.invalidate()
            connectionLifecycleTaskOwnership.pendingCachedReconnectPersistence = nil
        }
        for operation in connectionLifecycleTaskOwnership.deferredPersistenceOperations.values {
            operation.progress.markForgotten(macDeviceIDs)
            operation.fence.invalidate()
        }
        for task in connectionLifecycleTaskOwnership.deferredPersistenceTasks.values {
            task.cancel()
        }
    }

    func startDeferredCachedReconnectPersistence(
        _ operation: DeferredStoredMacReconnectPersistence
    ) {
        let id = UUID()
        let previousWrite = pairedMacWriteChain
        let task = Task { @MainActor [weak self] in
            await previousWrite?.value
            let result = await operation.run()
            guard let self else { return }
            self.connectionLifecycleTaskOwnership.deferredPersistenceTasks[id] = nil
            self.connectionLifecycleTaskOwnership.deferredPersistenceOperations[id] = nil
            if case .persisted(let visibleMacs) = result,
               operation.fence.isCurrent(operation.fenceGeneration) {
                self.applyLoadedPairedMacs(visibleMacs)
            }
            guard self.connectionLifecycleTaskOwnership.deferredPersistenceTasks.isEmpty else {
                return
            }
            if self.connectionLifecycleReconnectPendingAfterRetirement {
                self.replayReconnectPendingAfterRetirementIfPossible()
            } else if self.connectionLifecycleTaskOwnership.cachedRetiredTask == nil,
                      self.connectionState == .connected,
                      self.multiMacAggregationEnabled {
                self.scheduleSecondaryAggregation()
            }
        }
        pairedMacWriteChain = task
        connectionLifecycleTaskOwnership.deferredPersistenceOperations[id] = operation
        connectionLifecycleTaskOwnership.deferredPersistenceTasks[id] = task
    }
}
