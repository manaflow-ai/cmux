import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Synchronous admission makes the row disappear before the first network
    /// suspension. Every sidebar and CLI delete shares this request and result.
    func deleteCloudWorkspace(
        machine: SurfaceMachineID,
        workspaceID: String,
        provider suppliedProvider: (any SurfaceProvider)? = nil
    ) -> Task<Int, Error> {
        let ledger = cloudWorkspaceDeletionLedger
        let key = CloudWorkspaceDeletionLedger.Key(machine: machine, workspaceID: workspaceID)
        if let entry = ledger.entries[key] {
            if let existing = entry.task { return existing }
            if entry.completed { return Task { entry.closedTerminalCount } }
        }
        guard let token = ledger.begin(machine: machine, workspaceID: workspaceID, previous: authoritativeSnapshot) else {
            return Task { throw CancellationError() }
        }
        cloudWorkspaceCreationCoordinator.cancel(machine: machine, workspaceID: workspaceID)
        let projectionToken = cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
        notifyChange()
        let task = Task { @MainActor in
            defer {
                self.cloudWorkspaceProjectionCoordinator.endLocalMutation(projectionToken, on: machine, catalog: self)
                self.notifyChange()
            }
            do {
                try Task.checkCancellation()
                guard let provider = suppliedProvider ?? self.provider(for: machine) else {
                    throw SurfaceCatalogError.noProvider(machine)
                }
                try self.checkDeletionProvider(provider, machine: machine)
                await provider.refresh()
                try self.checkDeletionProvider(provider, machine: machine)
                // Read authoritative rows: the visible snapshot deliberately hides
                // this workspace already. Refresh captures terminals created while
                // the confirmation dialog was open.
                let doomed = self.authoritativeSnapshot.resources(on: machine).filter {
                    $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
                }
                ledger.rememberTerminals(Set(doomed.map(\.id)), key: key, token: token)
                self.notifyChange()
                for terminal in doomed {
                    try self.checkDeletionProvider(provider, machine: machine)
                    try await ledger.closeTerminal(terminal.id, provider: provider)
                }
                try self.checkDeletionProvider(provider, machine: machine)
                try await provider.closeRemoteWorkspace(id: workspaceID)
                guard self.provider(for: machine) === provider else { throw CancellationError() }
                // Once close returns successfully, cancellation must not undo a
                // committed remote mutation or display the old row again.
                _ = ledger.succeed(machine: machine, workspaceID: workspaceID, token: token, closedTerminalCount: doomed.count)
                if let state = self.cloudStates[machine], self.cloudStateObservations[machine]?.freshness == .current {
                    ledger.reconcile(state)
                }
                self.cloudWorkspaceProjectionCoordinator.request(machine: machine, catalog: self)
                return doomed.count
            } catch {
                _ = ledger.fail(machine: machine, workspaceID: workspaceID, token: token)
                // The catalog retained provider state throughout. Partial terminal
                // closes remain authoritative; rollback never invents live processes.
                self.cloudWorkspaceProjectionCoordinator.request(machine: machine, catalog: self)
                throw error
            }
        }
        ledger.attach(task, key: key, token: token)
        return task
    }

    func isCloudWorkspaceDeletionHidden(machine: SurfaceMachineID, workspaceID: String) -> Bool {
        cloudWorkspaceDeletionLedger.hides(machine: machine, workspaceID: workspaceID)
    }

    func isCloudWorkspaceDeletionPending(machine: SurfaceMachineID, workspaceID: String) -> Bool {
        cloudWorkspaceDeletionLedger.isPending(machine: machine, workspaceID: workspaceID)
    }

    /// Only a locally admitted delete may invalidate a captured navigation intent.
    /// Other destination failures keep their existing error path.
    func checkCloudWorkspaceNavigation(machine: SurfaceMachineID, workspaceID: String) throws {
        if isCloudWorkspaceDeletionHidden(machine: machine, workspaceID: workspaceID) { throw CancellationError() }
    }
    func isDeletingCloudResource(_ id: SurfaceResourceID, remoteWorkspaceID: String?) -> Bool {
        if let workspaceID = remoteWorkspaceID,
           isCloudWorkspaceDeletionHidden(machine: id.machine, workspaceID: workspaceID) { return true }
        return cloudWorkspaceDeletionLedger.entries.values.contains { $0.terminalIDs.contains(id) }
    }
    private func checkDeletionProvider(_ provider: any SurfaceProvider, machine: SurfaceMachineID) throws {
        try Task.checkCancellation()
        guard self.provider(for: machine) === provider else { throw CancellationError() }
    }

}
