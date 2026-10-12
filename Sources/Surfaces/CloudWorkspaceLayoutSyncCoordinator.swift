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
///
/// Only user edits are written. Each workspace keeps a baseline: the tree the machine's
/// layout last produced natively, or the tree last written. Resizes, programmatic
/// changes and restored-but-unreconciled trees match or lack a baseline and write
/// nothing, so they cannot overwrite a newer arrangement made by another client.
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
    private var entries: [UUID: Entry] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var baselines: [UUID: CloudLayoutSyncTree] = [:]
    /// Most recent result per workspace, for diagnostics and tests.
    private(set) var outcomes: [UUID: CloudLayoutSyncStep] = [:]

    /// Records that the native arrangement of `workspaceID` changed. Call synchronously
    /// from the edit so a graph event queued behind it cannot win the race.
    ///
    /// - Parameter desired: Reads the native tree of daemon-backed tabs at write time.
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
        guard isUserEdit(desired(), workspaceID: workspaceID) else { return }
        if let previous = entries[workspaceID] { finish(workspaceID, token: previous.token, catalog: catalog) }
        let token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
        entries[workspaceID] = Entry(machine: machine, remoteWorkspaceID: remoteWorkspaceID, token: token, desired: desired)
        tasks[workspaceID] = Task { @MainActor [weak self, weak catalog] in
            guard let self, let catalog else { return }
            await self.run(workspaceID, catalog: catalog)
            self.finish(workspaceID, token: token, catalog: catalog)
        }
    }

    /// The machine's arrangement now shows natively as `tree`; later native changes are
    /// compared with it.
    func machineLayoutApplied(workspaceID: UUID, tree: CloudLayoutSyncTree?) {
        baselines[workspaceID] = tree
    }

    /// Forgets a closed or unbound workspace and releases its reconciliation hold.
    func cancel(workspaceID: UUID, catalog: SurfaceCatalog) {
        baselines[workspaceID] = nil
        outcomes[workspaceID] = nil
        if let entry = entries[workspaceID] { finish(workspaceID, token: entry.token, catalog: catalog) }
    }

    func waitForIdle() async {
        for task in Array(tasks.values) { await task.value }
    }

    /// A tree differs from what the machine last produced here. Without a baseline the
    /// workspace has not reconciled since launch or reconnect, and its tree is not an edit.
    private func isUserEdit(_ tree: CloudLayoutSyncTree?, workspaceID: UUID) -> Bool {
        guard let tree, let baseline = baselines[workspaceID] else { return false }
        return !tree.isEquivalent(to: baseline)
    }

    private func run(_ workspaceID: UUID, catalog: SurfaceCatalog) async {
        var written = -1
        while let entry = entries[workspaceID], entry.generation != written {
            let generation = entry.generation
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let current = entries[workspaceID] else { return }
            // Another edit landed while waiting: wait for the burst to finish.
            guard current.generation == generation else { continue }
            // A closed or unbound workspace has nothing left to record.
            guard let binding = catalog.cloudWorkspaceProjectionCoordinator.environment.bindings()[workspaceID],
                  binding.vmID == current.machine.rawValue,
                  binding.remoteWorkspaceID == current.remoteWorkspaceID else { return }
            written = generation
            let tree = current.desired()
            guard let tree, isUserEdit(tree, workspaceID: workspaceID) else { continue }
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
            if step == .done { baselines[workspaceID] = tree }
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
