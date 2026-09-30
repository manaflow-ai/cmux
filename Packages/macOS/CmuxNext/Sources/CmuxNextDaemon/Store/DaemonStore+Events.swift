import Foundation

extension DaemonStore {
    /// What the caller must do after `apply(_:)`.
    public enum Followup: Equatable, Sendable {
        case none
        /// Refetch `list-workspaces` and apply it.
        case resync
    }

    /// Applies one event in place. Returns `.resync` when the event cannot be
    /// applied exactly (revision gap, generation change, coarse invalidation).
    @discardableResult
    public func apply(_ event: DaemonEvent) -> Followup {
        let followup = applyState(event)
        if let transaction = event.clientTransactionID {
            confirm(transaction)
        }
        return followup
    }

    /// Applies a batch in order; returns `.resync` when any event needs one.
    /// Events superseded by the last snapshot are skipped.
    @discardableResult
    public func apply(batch: [DaemonEventEnvelope]) -> Followup {
        var followup = Followup.none
        for envelope in batch {
            if envelope.sequence > snapshotBarrier || isLifecycle(envelope.event) {
                if apply(envelope.event) == .resync { followup = .resync }
            } else if let transaction = envelope.event.clientTransactionID {
                // Superseded by the snapshot, but its echo still settles the patch.
                confirm(transaction)
            }
        }
        // A batch that needs a resync is reflected only once the snapshot
        // lands (`resync` advances to its barrier).
        if followup == .none, let last = batch.map(\.sequence).max() { advanceAppliedSequence(to: last) }
        return followup
    }

    func advanceAppliedSequence(to sequence: UInt64) {
        if sequence > appliedSequence { appliedSequence = sequence }
    }

    private func isLifecycle(_ event: DaemonEvent) -> Bool {
        switch event {
        case .connected, .disconnected, .daemonShutdown: true
        default: false
        }
    }

    private func applyState(_ event: DaemonEvent) -> Followup {
        switch event {
        case .connected(let identity, _):
            connectionState = .connected(identity)
            noteHandshake(identity)
            return .resync
        case .disconnected(let reason):
            connectionState = .disconnected(reason)
            return .none
        case .daemonShutdown:
            connectionState = .disconnected("daemon shut down")
            return .none

        case .workspaceAdded(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                if let existing = store.workspaces.first(where: { $0.id == WorkspaceModel.identity(delta.entity) }) {
                    existing.update(delta.entity)
                } else {
                    let index = min(max(delta.index ?? store.workspaces.count, 0), store.workspaces.count)
                    store.workspaces.insert(WorkspaceModel(delta.entity), at: index)
                }
            }
        case .workspaceClosed(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                store.workspaces.removeAll { $0.id == WorkspaceModel.identity(delta.entity) }
            }
        case .workspaceRenamed(let delta), .workspaceChanged(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                store.workspaces.first { $0.id == WorkspaceModel.identity(delta.entity) }?.update(delta.entity)
            }
        case .workspaceMoved(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                let id = WorkspaceModel.identity(delta.entity)
                guard let from = store.workspaces.firstIndex(where: { $0.id == id }) else { return }
                let model = store.workspaces[from]
                model.update(delta.entity)
                let index = min(max(delta.index ?? store.workspaces.count - 1, 0), store.workspaces.count - 1)
                if index != from {
                    store.workspaces.remove(at: from)
                    store.workspaces.insert(model, at: index)
                }
            }

        case .screenAdded(let delta):
            guard let workspace = workspacesByHandle[delta.workspace] else { return .resync }
            if let existing = workspace.screens.first(where: { $0.id == ScreenModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let index = min(max(delta.index ?? workspace.screens.count, 0), workspace.screens.count)
                workspace.screens.insert(ScreenModel(delta.entity), at: index)
            }
            structureChanged()
            return .none
        case .screenClosed(let delta):
            guard let workspace = workspacesByHandle[delta.workspace],
                  workspace.screens.contains(where: { $0.handle == delta.screen }) else { return .none }
            workspace.screens.removeAll { $0.handle == delta.screen }
            structureChanged()
            return .none
        case .screenRenamed(let delta):
            guard let screen = screensByHandle[delta.screen] else { return .resync }
            screen.update(delta.entity)
            structureChanged()
            return .none

        case .paneAdded(let delta):
            guard let screen = screensByHandle[delta.screen] else { return .resync }
            if let existing = screen.panes.first(where: { $0.id == PaneModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let index = min(max(delta.index ?? screen.panes.count, 0), screen.panes.count)
                screen.panes.insert(PaneModel(delta.entity), at: index)
            }
            structureChanged()
            // The layout that places the pane arrives as `layout-changed`.
            return .none
        case .paneClosed(let delta):
            guard let screen = screensByHandle[delta.screen], screen.panes.contains(where: { $0.handle == delta.pane }) else {
                return .none
            }
            screen.panes.removeAll { $0.handle == delta.pane }
            structureChanged()
            return .none

        case .tabAdded(let delta):
            guard let pane = panesByHandle[delta.pane] else { return .resync }
            if let existing = pane.tabs.first(where: { $0.id == TabModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let tab = TabModel(delta.entity)
                tab.setAgent(agentsBySurface[delta.surface])
                pane.insertTab(tab, at: delta.index ?? pane.tabs.count)
            }
            structureChanged()
            return .none
        case .tabClosed(let delta):
            guard panesByHandle[delta.pane]?.removeTab(surface: delta.surface) != nil else { return .none }
            structureChanged()
            return .none
        case .tabRenamed(let delta), .tabChanged(let delta):
            guard let tab = tabsBySurface[delta.surface] else { return .resync }
            tab.update(delta.entity)
            panesByHandle[delta.pane]?.recomputeSpans()
            return .none

        case .treeChanged, .layoutChanged, .overflow:
            return .resync

        case .titleChanged(let surface, let title):
            tabsBySurface[surface]?.setTitle(title)
            return .none
        case .surfaceResized(let surface, let size):
            tabsBySurface[surface]?.setSize(size)
            return .none
        case .surfaceExited(let surface):
            tabsBySurface[surface]?.markDead()
            return .none
        case .notification(let notification):
            notifications.append(notification)
            if notifications.count > notificationLimit { notifications.removeFirst(notifications.count - notificationLimit) }
            // The daemon retains a marker only for an inactive target and
            // follows with `tree-changed`/`tab-changed`, which settle the state.
            return .none
        case .agentChanged(let status):
            agentsBySurface[status.surface] = status
            tabsBySurface[status.surface]?.setAgent(status)
            return .none

        case .scrollChanged, .bell, .frontendProjectionChanged, .terminalRegistryChanged, .client, .unknown:
            return .none
        }
    }

    private func applyWorkspaceDelta(_ delta: WorkspaceDelta, _ body: (DaemonStore, WorkspaceDelta) -> Void) -> Followup {
        if let generation = delta.generation, let current = self.generation, generation != current { return .resync }
        if let registry = delta.registryID, let current = registryID, registry != current { return .resync }
        if delta.workspaceRevision <= workspaceRevision { return .none }
        guard delta.workspaceRevision == workspaceRevision + 1 else { return .resync }
        body(self, delta)
        workspaceRevision = delta.workspaceRevision
        structureChanged()
        return .none
    }
}
