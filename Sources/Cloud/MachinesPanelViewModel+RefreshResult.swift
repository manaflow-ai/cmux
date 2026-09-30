import CmuxCloud
import CmuxCloudMachines
import Foundation

extension MachinesPanelViewModel {
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
            initialTransientFailureCount = 0
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .notConnectedToInternet {
            // The read coordinator's offline verdict (URLSession transport errors
            // arrive as backendUnreachable): not a list failure; offline owns it.
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
                initialTransientFailureCount = 0
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
        if listProblem == .unreachable, !hasLoadedOnce {
            initialTransientFailureCount = min(
                initialTransientFailureCount + 1,
                Self.initialTransientFailureLimit
            )
        } else if listProblem != .unreachable {
            initialTransientFailureCount = 0
        }
        hasLoadedOnce = hasLoadedOnce || listProblem != .unreachable
        #if DEBUG
        cmuxDebugLog("cloud.machines.list settled count=\(machines.count) problem=\(String(describing: listProblem))")
        #endif
    }
}
