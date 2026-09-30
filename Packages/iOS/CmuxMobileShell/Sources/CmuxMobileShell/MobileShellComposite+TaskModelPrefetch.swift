internal import CmuxMobileShellModel
internal import CmuxMobilePairedMac
import Foundation

struct MobileTaskModelPrefetchKey: Hashable {
    let pairingID: String
    let connectionIdentity: String?
    let provider: MobileTaskAgentProvider
}

actor MobileTaskModelPrefetchLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

extension MobileShellComposite {
    /// Re-evaluated as the paired-Mac list or any connection identity changes.
    public var taskModelPrefetchTargets: [MobileTaskModelPrefetchTarget] {
        guard isSignedIn else { return [] }
        return taskComposerPairedMacs.map { mac in
            let identity = taskModelConnectionIdentity(
                macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag
            )
            return MobileTaskModelPrefetchTarget(
                macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag,
                connectionIdentity: identity
            )
        }
    }

    /// Warms every provider on every paired Mac and waits for the current queue.
    public func prefetchTaskModels(for targets: [MobileTaskModelPrefetchTarget]) async {
        updateTaskModelPrefetchTargets(targets)
        let tasks = Array(taskModelPrefetchTasks.values)
        for task in tasks {
            await task.value
        }
    }

    /// Reconciles background warming without cancelling work for unchanged Macs.
    /// An empty snapshot ends prefetching when the scene leaves the foreground.
    public func updateTaskModelPrefetchTargets(_ targets: [MobileTaskModelPrefetchTarget]) {
        guard isSignedIn, !targets.isEmpty else {
            cancelTaskModelPrefetchTasks()
            return
        }
        let targetByPairingID = Dictionary(
            uniqueKeysWithValues: targets.map {
                (MobilePairedMac.pairingID(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ), $0)
            }
        )
        for key in taskModelPrefetchTasks.keys {
            guard let target = targetByPairingID[key.pairingID],
                  target.connectionIdentity == key.connectionIdentity else {
                taskModelPrefetchTasks[key]?.cancel()
                taskModelPrefetchTasks[key] = nil
                continue
            }
        }

        for target in targets {
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: target.macDeviceID,
                instanceTag: target.instanceTag
            )
            for provider in MobileTaskAgentProvider.allCases {
                let key = prefetchTaskKey(
                    pairingID: pairingID, connectionIdentity: target.connectionIdentity,
                    provider: provider
                )
                if taskModelPrefetchTasks[key] != nil {
                    continue
                }
                let catalog = taskModelPrefetchCatalogSnapshot()
                let limiter = taskModelPrefetchLimiter
                let token = UUID()
                let task = Task { @MainActor [weak self] in
                    defer {
                        if let self,
                           self.taskModelPrefetchTaskTokens[key] == token {
                            self.taskModelPrefetchTasks[key] = nil
                            self.taskModelPrefetchTaskTokens[key] = nil
                            if self.taskModelPrefetchTasks.isEmpty {
                                self.taskModelPrefetchCatalog?.cancel()
                                self.taskModelPrefetchCatalog = nil
                            }
                        }
                    }
                    await limiter.acquire()
                    guard !Task.isCancelled else {
                        await limiter.release()
                        return
                    }
                    if let self {
                        await self.prefetchTaskModel(
                            provider: provider, target: target, catalog: catalog
                        )
                    }
                    await limiter.release()
                }
                taskModelPrefetchTasks[key] = task
                taskModelPrefetchTaskTokens[key] = token
            }
        }
    }

    private func taskModelPrefetchCatalogSnapshot() -> MobileTaskModelPrefetchCatalog {
        let now = runtime?.now() ?? Date()
        if let catalog = taskModelPrefetchCatalog,
           now.timeIntervalSince(catalog.startedAt) < 300 {
            return catalog
        }
        let catalog = MobileTaskModelPrefetchCatalog(client: taskModelCatalogClient, startedAt: now)
        taskModelPrefetchCatalog = catalog
        return catalog
    }

    private func prefetchTaskKey(
        pairingID: String,
        connectionIdentity: String?,
        provider: MobileTaskAgentProvider
    ) -> MobileTaskModelPrefetchKey {
        MobileTaskModelPrefetchKey(
            pairingID: pairingID,
            connectionIdentity: connectionIdentity,
            provider: provider
        )
    }

    func cancelTaskModelPrefetchTasks(keeping pairingIDs: Set<String>? = nil) {
        let keys = taskModelPrefetchTasks.keys.filter { key in
            pairingIDs?.contains(key.pairingID) != true
        }
        for key in keys {
            taskModelPrefetchTasks[key]?.cancel()
            taskModelPrefetchTasks[key] = nil
            taskModelPrefetchTaskTokens[key] = nil
        }
        if taskModelPrefetchTasks.isEmpty {
            taskModelPrefetchCatalog?.cancel()
            taskModelPrefetchCatalog = nil
        }
    }

    @MainActor
    private func prefetchTaskModel(
        provider: MobileTaskAgentProvider,
        target: MobileTaskModelPrefetchTarget,
        catalog: MobileTaskModelPrefetchCatalog
    ) async {
        guard !Task.isCancelled,
              isSignedIn,
              taskModelConnectionIdentity(
                  macDeviceID: target.macDeviceID, instanceTag: target.instanceTag
              ) == target.connectionIdentity else { return }
        _ = await refreshTaskModels(
            provider: provider, macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag, maximumCacheAge: 300,
            prefetchedCatalog: catalog
        )
    }
}
