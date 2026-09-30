import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Writes native Cloud workspace arrangements to their machine.
///
/// The machine's layout document is the durable record of a bound workspace: the
/// projection coordinator re-derives the native split tree from it on every graph
/// change, restore and reconnect. A native edit (tab dragged to another pane, a split
/// by drag, a reorder, a divider drag) is therefore written back here, and native
/// reconciliation for that machine is suspended from the edit until the machine has
/// accepted it, so an older graph can never re-apply the arrangement being replaced.
@MainActor
final class CloudWorkspaceLayoutSyncCoordinator {
    private struct Entry {
        var machine: SurfaceMachineID
        var remoteWorkspaceID: String
        var token: UUID
        var desired: @MainActor () -> CloudLayoutSyncTree?
        var generation = 0
    }

    /// Coalesces a divider drag or a burst of tab moves into one write.
    var debounce: Duration = .milliseconds(150)
    /// A pending terminal creation settles within this window; later it is another client's tab.
    var retryDelay: Duration = .milliseconds(400)
    var retryLimit = 12
    private var entries: [UUID: Entry] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The last tree each workspace was confirmed against, to ignore geometry-only events.
    private var confirmed: [UUID: CloudLayoutSyncTree] = [:]
    /// Most recent result per workspace, for diagnostics and tests.
    private(set) var outcomes: [UUID: CloudLayoutSyncStep] = [:]

    /// Records that the native arrangement of `workspaceID` changed. Call synchronously
    /// from the edit so a graph event queued behind it cannot win the race.
    ///
    /// - Parameter desired: Reads the native tree at write time, or nil while a pane
    ///   has no daemon tab yet (a creation in flight or a local-only view).
    func layoutDidChange(
        workspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String,
        catalog: SurfaceCatalog,
        desired: @escaping @MainActor () -> CloudLayoutSyncTree?
    ) {
        if var entry = entries[workspaceID], entry.machine == machine, entry.remoteWorkspaceID == remoteWorkspaceID {
            entry.desired = desired
            entry.generation += 1
            entries[workspaceID] = entry
            return
        }
        // Size-only events (window resize, sidebar toggle) keep the same tree.
        if let tree = desired(), confirmed[workspaceID] == tree { return }
        if let previous = entries[workspaceID] { finish(workspaceID, token: previous.token, catalog: catalog) }
        let token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
        entries[workspaceID] = Entry(machine: machine, remoteWorkspaceID: remoteWorkspaceID, token: token, desired: desired)
        tasks[workspaceID] = Task { @MainActor [weak self, weak catalog] in
            guard let self, let catalog else { return }
            await self.run(workspaceID, catalog: catalog)
            self.finish(workspaceID, token: token, catalog: catalog)
        }
    }

    /// Forgets a closed or unbound workspace and releases its reconciliation hold.
    func cancel(workspaceID: UUID, catalog: SurfaceCatalog) {
        confirmed[workspaceID] = nil
        outcomes[workspaceID] = nil
        if let entry = entries[workspaceID] { finish(workspaceID, token: entry.token, catalog: catalog) }
    }

    /// The machine's arrangement was just applied natively. The next native edit must
    /// be compared with the machine again, even if it restores an earlier tree.
    func machineLayoutApplied(workspaceID: UUID) {
        confirmed[workspaceID] = nil
    }

    func waitForIdle() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func run(_ workspaceID: UUID, catalog: SurfaceCatalog) async {
        var written = -1
        var retries = 0
        while let entry = entries[workspaceID], entry.generation != written {
            let generation = entry.generation
            try? await Task.sleep(for: retries == 0 ? debounce : retryDelay)
            guard !Task.isCancelled, let current = entries[workspaceID] else { return }
            // A closed or unbound workspace has nothing left to record.
            guard let binding = catalog.cloudWorkspaceProjectionCoordinator.environment.bindings()[workspaceID],
                  binding.vmID == current.machine.rawValue,
                  binding.remoteWorkspaceID == current.remoteWorkspaceID else { return }
            // Another edit landed while waiting: wait for the burst to finish.
            guard current.generation == generation else { continue }
            guard let tree = current.desired() else {
                guard retries < retryLimit else { return }
                retries += 1
                continue
            }
            let step: CloudLayoutSyncStep
            if let state = catalog.cloudStates[current.machine], let snapshot = state.snapshotObject(),
               CloudLayoutSyncPlanner(snapshot: snapshot, workspaceID: current.remoteWorkspaceID, desired: tree).step == .done {
                step = .done
            } else if let provider = catalog.provider(for: current.machine) as? any SurfaceWorkspaceLayoutSyncing {
                do {
                    step = try await provider.syncWorkspaceLayout(tree, remoteWorkspaceID: current.remoteWorkspaceID)
                } catch is CancellationError {
                    return
                } catch {
                    step = .notReady(CloudMachineLink.errorText(error))
                }
            } else {
                return
            }
            outcomes[workspaceID] = step
#if DEBUG
            cmuxDebugLog("cloudWorkspace.layoutSync workspace=\(workspaceID) remote=\(current.remoteWorkspaceID) step=\(step)")
#endif
            switch step {
            case .done:
                confirmed[workspaceID] = tree
                written = generation
                retries = 0
            case .notReady where retries < retryLimit:
                retries += 1
            default:
                written = generation
            }
        }
    }

    /// Releases exactly the hold `token` names; a superseded task cannot end its successor.
    private func finish(_ workspaceID: UUID, token: UUID, catalog: SurfaceCatalog) {
        guard let entry = entries[workspaceID], entry.token == token else { return }
        entries[workspaceID] = nil
        tasks.removeValue(forKey: workspaceID)?.cancel()
        catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(entry.token, on: entry.machine, catalog: catalog)
    }
}
