import CmuxCloudMachines
import Foundation

/// Refresh ownership stays on the panel; only immutable requests survive suspension.
extension MachinesPanelViewModel {
    func refreshStats() {
        guard isCloudEnabled(), statsTask == nil, let client = client ?? VMClient.shared else { return }
        let ids = machines.filter { $0.capabilities.stats }.map(\.id)
        guard !ids.isEmpty else { return }
        let requestID = UUID()
        statsID = requestID
        statsTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { _ = try? await client.stats(id: id) } }
            }
            guard let self, self.statsID == requestID else { return }
            self.statsTask = nil
            self.statsID = nil
        }
    }

    /// Read the current shared resource owner, retaining its resize and list fences.
    func applyResourceStats(machineIDs: Set<String>?) {
        guard isCloudEnabled(), let resourceStats else { return }
        for id in machineIDs ?? Set(machineIndexByID.keys) {
            guard let index = machineIndexByID[id], machines.indices.contains(index),
                  machines[index].id == id, machines[index].capabilities.stats else { continue }
            let stats = resourceStats.stats(for: id)
            if machines[index].stats != stats { machines[index].stats = stats }
        }
    }

    func refresh() {
        guard isCloudEnabled(), let client = client ?? VMClient.shared else { return }
        guard refreshTask == nil else { refreshRequestedWhileLoading = true; return }
        isLoading = true
        let generation = refreshGeneration
        let scope = machinePinStore?.scopeIdentifier
        refreshTask = Task { [weak self] in
            let result: Result<VMListPage, Error>
            do { result = .success(try await client.listPage()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, generation == self.refreshGeneration else { return }
            self.applyRefreshResult(result, generation: generation, scope: scope)
            self.refreshTask = nil
            if self.refreshRequestedWhileLoading {
                self.refreshRequestedWhileLoading = false
                self.refresh()
            }
        }
    }

    func startPolling() {
        wantsPolling = true
        guard isCloudEnabled() else { pausePolling(); return }
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, pollingClock] in
            while !Task.isCancelled {
                do { try await pollingClock.sleep(for: Self.pollInterval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func stopPolling() { wantsPolling = false; pausePolling() }

    func pausePolling() {
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshRequestedWhileLoading = false
        refreshGeneration &+= 1
        isLoading = false
        statsTask?.cancel(); statsTask = nil; statsID = nil
        usageTask?.cancel(); usageTask = nil
        usageFailureCount = 0
        usageRetryNotBefore = nil
        treeTask?.cancel(); treeTask = nil
        machineRefreshes.cancelAll()
        freeAccessTransitionTask?.cancel(); freeAccessTransitionTask = nil
    }

    func clearUnavailableMetrics() {
        if let resourceStats {
            for id in machineIndexByID.keys {
                _ = resourceStats.finishRead(resourceStats.beginRead(machineID: id), stats: nil)
            }
            applyResourceStats(machineIDs: nil)
        }
        usageByMachineID = [:]
        machines = MachineSnapshotBuilder.applyingUsage(to: machines, usage: [:])
    }

    func applyRefreshResult(_ result: Result<VMListPage, Error>, generation: UInt64, scope: String?) {
        guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier, isCloudEnabled() else { return }
        do {
            let page = try result.get()
            try Task.checkCancellation()
            guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier,
                  isCloudEnabled() else { return }
            let previous = resourceStats?.snapshot ?? [:]
            let freeAccessWindowDays = page.limits?.freeAccessWindowDays ?? 0
            self.freeAccessWindowDays = freeAccessWindowDays
            var snapshots = page.vms.map {
                MachineSnapshotBuilder.snapshot(
                    from: $0,
                    freeAccessWindowDays: freeAccessWindowDays,
                    previousStats: previous[$0.id]
                )
            }
            snapshots = MachineSnapshotBuilder.applyingUsage(to: snapshots, usage: usageByMachineID)
            let defaultMachineID = defaultMachineStore?.resolveMachineID(
                from: snapshots.map { CloudMachineDescriptor(id: $0.id, isDesktop: $0.isDesktop) },
                isComplete: true
            )
            snapshots = snapshots.map { snapshot in
                var next = snapshot
                next.isDefault = snapshot.id == defaultMachineID
                return next
            }
            // The authoritative fleet plus catalog-only rows is the complete
            // visible set: a pin whose machine is gone from both is pruned.
            machinePinStore?.reconcile(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(snapshots, catalog: scopedCatalogSnapshot()).map(\.id))
            machineIndexByID = Dictionary(uniqueKeysWithValues: snapshots.enumerated().map { ($0.element.id, $0.offset) })
            machines = snapshots
            lastLimits = page.limits
            scheduleFreeAccessTransition()
            refreshStats()
            refreshUsage()
            readCatalog()
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: snapshots.count, limits: page.limits, machines: snapshots)
            lastErrorDescription = nil
            listProblem = nil
        } catch is CancellationError {
            return
        } catch let error as VMClientError {
            guard !Task.isCancelled, generation == refreshGeneration,
                  scope == machinePinStore?.scopeIdentifier else { return }
            if case .notSignedIn = error {
                machines = []
                machineIndexByID.removeAll()
                plan = nil
                activeOperation = nil
                lastErrorDescription = nil
                listProblem = nil
                hasLoadedOnce = false
                isLoading = false
                return
            }
            lastErrorDescription = String(describing: error)
            listProblem = Self.classifyListFailure(error)
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration,
                  scope == machinePinStore?.scopeIdentifier else { return }
            lastErrorDescription = String(describing: error)
            listProblem = .unreachable
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
