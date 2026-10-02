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
        let followup = withOverlayLifted { applyEvent(event, sequence: nil) }
        workspaceListMayHaveChanged()
        // Waiters see the visible state, so they run once the overlay is back.
        flushAppliedWaiters()
        return followup
    }

    /// Applies one event to the confirmed records (the overlay is lifted)
    /// and settles what its transaction echo confirms. Whether the echo
    /// needs a resync is decided per event: the echo's own delta applied
    /// exactly holds the intent's result even when another event of the
    /// batch needs a resync.
    private func applyEvent(_ event: DaemonEvent, sequence: UInt64?) -> Followup {
        let followup = applyState(event)
        if let transaction = event.clientTransactionID {
            confirm(transaction)
            settleIntentOnEcho(transaction, needsResync: followup == .resync, sequence: sequence)
        }
        return followup
    }

    /// Applies a batch in order; returns `.resync` when any event needs one.
    /// Events superseded by the last snapshot are skipped.
    @discardableResult
    public func apply(batch: [DaemonEventEnvelope]) -> Followup {
        // An observer that applies events while this batch applies is an
        // update cycle (idle-wakeups.md): counted, logged in debug builds.
        updateCycles.run { applyBatch(batch) }
    }

    private func applyBatch(_ batch: [DaemonEventEnvelope]) -> Followup {
        applyDepth += 1
        defer {
            applyDepth -= 1
            workspaceListMayHaveChanged()
            // Whole batch applied: settle the transactions it confirmed.
            flushAppliedWaiters()
        }
        return withOverlayLifted {
            var followup = Followup.none
            for envelope in batch {
                if envelope.sequence > snapshotBarrier || isLifecycle(envelope.event) {
                    if applyEvent(envelope.event, sequence: envelope.sequence) == .resync { followup = .resync }
                } else if let transaction = envelope.event.clientTransactionID {
                    // Superseded by the snapshot (which holds its result),
                    // but its echo still settles the patch and the intent.
                    confirm(transaction)
                    settleIntentOnEcho(transaction, needsResync: false, sequence: envelope.sequence)
                }
            }
            // A batch that needs a resync is reflected only once the snapshot
            // lands (`resync` advances to its barrier).
            if followup == .none, let last = batch.map(\.sequence).max() { advanceAppliedSequence(to: last) }
            return followup
        }
    }

    func advanceAppliedSequence(to sequence: UInt64) {
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        // Intents first, so waiters see the visible state without them.
        settleDueIntents()
        runAppliedWaiters(nil)
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
            connectionEpoch += 1
            connectionState = .connected(identity)
            noteHandshake(identity)
            return .resync
        case .disconnected(let reason):
            connectionEpoch += 1
            connectionState = .disconnected(reason)
            // Nothing newer will arrive for commands sent on this connection.
            drainAppliedWaiters = true
            flushAppliedWaiters()
            return .none
        case .daemonShutdown:
            connectionEpoch += 1
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
        case .screenChanged(let delta):
            guard let workspace = workspacesByHandle[delta.workspace], let screen = screensByHandle[delta.screen],
                  workspace.screens.contains(where: { $0 === screen }) else { return .resync }
            screen.update(delta.entity)
            if let index = delta.index { workspace.moveScreen(screen, to: index) }
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
            // tab-drag-v1 reports a move as the moved tab's tab-changed
            // naming its new pane (another pane, screen or a new workspace).
            guard let target = panesByHandle[delta.pane] else { return .resync }
            if relocate(tab, to: target, index: delta.index) {
                structureChanged()
            } else if let index = delta.index {
                // A move inside the pane: the delta names the tab's index.
                target.moveTab(surface: tab.surface, to: index)
            } else {
                target.recomputeSpans()
            }
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

        case .bookmarksChanged, .conversationChanged, .conversationTyping:
            sideEvents.deliver(event)
            return .none

        case .scrollChanged, .bell, .frontendProjectionChanged, .terminalRegistryChanged, .client, .unknown:
            return .none
        }
    }

    /// Moves `tab` into `target` at `index` when another pane holds it.
    /// Returns whether anything moved.
    private func relocate(_ tab: TabModel, to target: PaneModel, index: Int?) -> Bool {
        let holders = panesByHandle.values.filter { $0 !== target && $0.tabs.contains { $0.surface == tab.surface } }
        guard !holders.isEmpty else { return false }
        for pane in holders { _ = pane.removeTab(surface: tab.surface) }
        if !target.tabs.contains(where: { $0.surface == tab.surface }) {
            target.insertTab(tab, at: min(max(index ?? target.tabs.count, 0), target.tabs.count))
        }
        return true
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
