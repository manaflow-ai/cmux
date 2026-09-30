internal import CmuxMobileShellModel
internal import CmuxMobilePairedMac
import Foundation

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
        let workers = Array(taskModelPrefetchWorkers.values)
        for worker in workers {
            await worker.value
        }
    }

    /// Reconciles background warming without cancelling work for unchanged Macs.
    /// An empty snapshot ends prefetching when the scene leaves the foreground.
    public func updateTaskModelPrefetchTargets(_ targets: [MobileTaskModelPrefetchTarget]) {
        guard isSignedIn, !targets.isEmpty else {
            cancelTaskModelPrefetchTasks()
            return
        }
        let desiredTargets = Dictionary(
            uniqueKeysWithValues: targets.flatMap { target in
                MobileTaskAgentProvider.allCases.map { provider in
                    let pairingID = MobilePairedMac.pairingID(
                        macDeviceID: target.macDeviceID,
                        instanceTag: target.instanceTag
                    )
                    return (
                        MobileTaskModelPrefetchKey(
                            pairingID: pairingID,
                            connectionIdentity: target.connectionIdentity,
                            provider: provider
                        ),
                        target
                    )
                }
            }
        )
        taskModelPrefetchDesiredTargets = desiredTargets
        taskModelPrefetchCompletedKeys = taskModelPrefetchCompletedKeys.filter {
            desiredTargets[$0] != nil
        }
        for key in taskModelPrefetchTasks.keys
            where desiredTargets[key] == nil {
            taskModelPrefetchTasks[key]?.cancel()
            taskModelPrefetchTasks[key] = nil
            taskModelPrefetchTaskTokens[key] = nil
        }
        startTaskModelPrefetchWorkersIfNeeded()
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

    func cancelTaskModelPrefetchTasks(keeping pairingIDs: Set<String>? = nil) {
        let keys = taskModelPrefetchDesiredTargets.keys.filter { key in
            pairingIDs?.contains(key.pairingID) != true
        }
        for key in keys { taskModelPrefetchDesiredTargets[key] = nil }
        taskModelPrefetchCompletedKeys.subtract(keys)
        for key in keys {
            taskModelPrefetchTasks[key]?.cancel()
            taskModelPrefetchTasks[key] = nil
            taskModelPrefetchTaskTokens[key] = nil
        }
        if taskModelPrefetchDesiredTargets.isEmpty {
            for worker in taskModelPrefetchWorkers.values { worker.cancel() }
            taskModelPrefetchWorkers.removeAll()
            taskModelPrefetchCatalog?.cancel()
            taskModelPrefetchCatalog = nil
        }
    }

    private func startTaskModelPrefetchWorkersIfNeeded() {
        guard !taskModelPrefetchDesiredTargets.isEmpty else { return }
        let pendingCount = taskModelPrefetchDesiredTargets.keys.filter {
            !taskModelPrefetchCompletedKeys.contains($0)
                && taskModelPrefetchTasks[$0] == nil
        }.count
        let workerCount = min(4, pendingCount)
        guard workerCount > taskModelPrefetchWorkers.count else { return }
        for _ in taskModelPrefetchWorkers.count..<workerCount {
            let workerID = UUID()
            let worker = Task { @MainActor [weak self] in
                defer { self?.taskModelPrefetchWorkers[workerID] = nil }
                await self?.runTaskModelPrefetchWorker()
            }
            taskModelPrefetchWorkers[workerID] = worker
        }
    }

    private func runTaskModelPrefetchWorker() async {
        while !Task.isCancelled {
            guard let key = taskModelPrefetchDesiredTargets.keys.first(where: {
                !taskModelPrefetchCompletedKeys.contains($0)
                    && taskModelPrefetchTasks[$0] == nil
            }), let target = taskModelPrefetchDesiredTargets[key] else {
                return
            }
            let catalog = taskModelPrefetchCatalogSnapshot()
            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prefetchTaskModel(
                    provider: key.provider, target: target, catalog: catalog
                )
            }
            taskModelPrefetchTasks[key] = task
            taskModelPrefetchTaskTokens[key] = token
            await task.value
            guard taskModelPrefetchTaskTokens[key] == token else { continue }
            taskModelPrefetchTasks[key] = nil
            taskModelPrefetchTaskTokens[key] = nil
            if taskModelPrefetchDesiredTargets[key] == target {
                taskModelPrefetchCompletedKeys.insert(key)
            }
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
