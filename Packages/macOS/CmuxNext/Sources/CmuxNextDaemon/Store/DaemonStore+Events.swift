import Foundation

extension DaemonStore {
    /// What the caller must do after `apply(_:)`.
    public enum Followup: Equatable, Sendable {
        case none
        /// Refetch `list-workspaces` and apply it.
        case resync
        /// Refetch `list-personal` alone and apply it (`personal-changed`).
        case personal
    }

    /// Applies one event in place. Returns `.resync` when the event cannot be
    /// applied exactly (revision gap, generation change, coarse invalidation).
    @discardableResult
    public func apply(_ event: DaemonEvent) -> Followup {
        var followup = withOverlayLifted { applyEvent(event, sequence: nil) }
        // One event without a sequence: its personal state is fetched now (no barrier to hold back).
        if followup == .personal {
            followup = .none
            refetchPersonal()
        }
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
    private func applyEvent(_ event: DaemonEvent, sequence: UInt64?, envelope: DaemonEventEnvelope? = nil) -> Followup {
        // Before it applies: the workspace it names is found while the records still hold it (a close).
        noteSnapshotTouch(event)
        let followup = applyState(event, envelope: envelope)
        if let transaction = event.clientTransactionID {
            confirm(transaction)
            ProvisionalTab.echoed(event, transaction: transaction, in: self)
            settleIntentOnEcho(transaction, needsResync: followup == .resync, sequence: sequence)
        } else {
            ProvisionalTab.matched(event, in: self)
        }
        return followup
    }

    /// Applies a batch in order; returns `.resync` when any event needs one.
    /// Events superseded by the last snapshot are skipped.
    @discardableResult
    public func apply(batch: [DaemonEventEnvelope]) -> Followup {
        // A staged script batch keeps the events of the workspaces it touches (DaemonStore+Stage.swift).
        let batch = stage?.passing(batch, in: self) ?? batch
        guard !batch.isEmpty else { return .none }
        // An observer that applies events while this batch applies is an
        // update cycle (idle-wakeups.md): counted, logged in debug builds.
        return updateCycles.run { applyBatch(batch) }
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
                if envelope.sequence > snapshotBarrier || envelope.event.outlivesSnapshot {
                    switch applyEvent(envelope.event, sequence: envelope.sequence, envelope: envelope) {
                    case .resync: followup = .resync
                    case .personal:
                        personalRefetch.saw(envelope.sequence)
                        if followup == .none { followup = .personal }
                    case .none: break
                    }
                } else if let transaction = envelope.event.clientTransactionID {
                    // Superseded by the snapshot (which holds its result),
                    // but its echo still settles the patch and the intent,
                    // and names a create's tab in the snapshot's records: a
                    // creation the person closed first keeps hiding (and then
                    // closes) that tab instead of leaving the log with it
                    // shown (tab-spam-race: a resync during Cmd-T/Cmd-W spam).
                    confirm(transaction)
                    ProvisionalTab.echoed(envelope.event, transaction: transaction, in: self)
                    settleIntentOnEcho(transaction, needsResync: false, sequence: envelope.sequence)
                }
            }
            // A batch that needs a resync is reflected only once the snapshot
            // lands (`resync` advances to its barrier); one with a personal change
            // only up to that change, until `list-personal` lands (`refetchPersonal`).
            if followup != .resync, let last = batch.map(\.sequence).max() {
                advanceAppliedSequence(to: personalRefetch.reachable(applying: last))
            }
            return followup
        }
    }

    func advanceAppliedSequence(to sequence: UInt64) {
        // Not past an event a stage still holds: nothing it holds counts as applied yet.
        let sequence = stage?.cappedSequence(sequence) ?? sequence
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        // Intents first, so waiters see the visible state without them.
        settleDueIntents()
        runAppliedWaiters(nil)
    }

    private func applyState(_ event: DaemonEvent, envelope: DaemonEventEnvelope?) -> Followup {
        switch event {
        case .connected(let identity, _):
            return DaemonConnectionChange.connected(identity, envelope).apply(to: self)
        case .disconnected(let reason):
            return DaemonConnectionChange.disconnected(reason).apply(to: self)
        case .daemonShutdown:
            return DaemonConnectionChange.shutdown.apply(to: self)

        case .workspaceAdded(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                if let existing = store.index.workspacesByID[WorkspaceModel.identity(delta.entity)] {
                    existing.update(delta.entity)
                    store.indexed(existing)
                } else {
                    let index = min(max(delta.index ?? store.workspaces.count, 0), store.workspaces.count)
                    let workspace = store.confirmedWorkspace(delta.entity)
                    store.workspaces.insert(workspace, at: index)
                    store.indexed(workspace)
                }
                store.sidebarNeedsRecompute = true
            }
        case .workspaceClosed(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                guard let closed = store.index.workspacesByID[WorkspaceModel.identity(delta.entity)] else { return }
                store.workspaces.removeAll { $0 === closed }
                store.index.remove(closed)
                store.sidebarNeedsRecompute = true
            }
        case .workspaceRenamed(let delta), .workspaceChanged(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                guard let workspace = store.index.workspacesByID[WorkspaceModel.identity(delta.entity)] else { return }
                let group = workspace.group
                workspace.update(delta.entity)
                store.indexed(workspace)
                if workspace.group != group { store.sidebarNeedsRecompute = true }
            }
        case .workspaceMoved(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                let id = WorkspaceModel.identity(delta.entity)
                guard let from = store.workspaces.firstIndex(where: { $0.id == id }),
                      let model = store.workspaces[checked: from] else { return }
                model.update(delta.entity)
                store.indexed(model)
                let index = min(max(delta.index ?? store.workspaces.count - 1, 0), store.workspaces.count - 1)
                if index != from {
                    store.workspaces.remove(at: from)
                    store.workspaces.insert(model, at: index)
                    store.index.noteTabOrderChanged()
                }
                store.sidebarNeedsRecompute = true
            }

        case .screenAdded(let delta):
            guard let workspace = index.workspacesByHandle[delta.workspace] else { return .resync }
            if let existing = workspace.screens.first(where: { $0.id == ScreenModel.identity(delta.entity) }) {
                existing.update(delta.entity)
                indexed(existing, in: workspace)
            } else {
                let index = min(max(delta.index ?? workspace.screens.count, 0), workspace.screens.count)
                let screen = ScreenModel(delta.entity)
                workspace.screens.insert(screen, at: index)
                indexed(screen, in: workspace)
            }
            return .none
        case .screenClosed(let delta):
            guard let workspace = index.workspacesByHandle[delta.workspace],
                  let screen = workspace.screens.first(where: { $0.handle == delta.screen }) else { return .none }
            workspace.screens.removeAll { $0 === screen }
            index.remove(screen)
            session.lay(workspaceOnly: workspace)
            return .none
        case .screenRenamed(let delta):
            guard let screen = screensByHandle[delta.screen], let workspace = index.workspace(holding: screen) else { return .resync }
            screen.update(delta.entity)
            indexed(screen, in: workspace)
            return .none
        case .screenChanged(let delta):
            guard let workspace = index.workspacesByHandle[delta.workspace], let screen = screensByHandle[delta.screen],
                  index.workspace(holding: screen) === workspace else { return .resync }
            screen.update(delta.entity)
            if let index = delta.index {
                workspace.moveScreen(screen, to: index)
                self.index.noteTabOrderChanged()
            }
            indexed(screen, in: workspace)
            return .none

        case .paneAdded(let delta):
            guard let screen = screensByHandle[delta.screen] else { return .resync }
            // A pending split's pane, seen once: if it closes before a layout places it, the split settles.
            if !intentLog.isEmpty { intentLog.noteDaemonPane(PaneModel.identity(delta.entity)) }
            if let existing = screen.panes.first(where: { $0.id == PaneModel.identity(delta.entity) }) {
                existing.update(delta.entity)
                indexed(existing, in: screen)
            } else {
                let index = min(max(delta.index ?? screen.panes.count, 0), screen.panes.count)
                let pane = confirmedPane(delta.entity)
                screen.panes.insert(pane, at: index)
                indexed(pane, in: screen)
            }
            // The layout that places the pane arrives as `layout-changed`.
            return .none
        case .paneClosed(let delta):
            guard let screen = screensByHandle[delta.screen], let pane = screen.pane(delta.pane) else { return .none }
            screen.panes.removeAll { $0 === pane }
            index.remove(pane)
            return .none

        case .tabAdded(let delta):
            guard let pane = panesByHandle[delta.pane] else { return .resync }
            if let existing = pane.tabs.first(where: { $0.id == TabModel.identity(delta.entity) }) {
                existing.update(delta.entity)
                indexed(existing, in: pane)
            } else {
                let tab = TabModel(delta.entity)
                tab.setAgent(agents.bySurface[delta.surface])
                pane.insertTab(tab, at: delta.index ?? pane.tabs.count)
                indexed(tab, in: pane)
            }
            return .none
        case .tabClosed(let delta):
            guard let tab = panesByHandle[delta.pane]?.removeTab(surface: delta.surface) else { return .none }
            index.remove(tab)
            return .none
        case .tabRenamed(let delta), .tabChanged(let delta):
            guard let tab = tabsBySurface[delta.surface] else { return .resync }
            tab.update(delta.entity)
            // tab-drag-v1 reports a move as the moved tab's tab-changed
            // naming its new pane (another pane, screen or a new workspace).
            guard let target = panesByHandle[delta.pane] else {
                if let holder = index.pane(holding: tab) { indexed(tab, in: holder) }
                return .resync
            }
            // Every other pane holding the surface gives it up; for a move into a new workspace
            // or screen, its added delta may have carried a second record of the tab already.
            var moved = false
            for record in index.tabs(onSurface: delta.surface) {
                guard let holder = index.pane(holding: record), holder !== target else { continue }
                _ = holder.removeTab(surface: delta.surface)
                index.remove(record)
                moved = true
            }
            let inTarget = target.tabs.contains { $0.surface == delta.surface }
            if moved, !inTarget {
                target.insertTab(tab, at: delta.index ?? target.tabs.count)
            } else if !inTarget {
                // No pane holds the tab: the records are out of step with the daemon.
                return .resync
            } else if let index = delta.index {
                // A move inside the pane: the delta names the tab's index.
                target.moveTab(surface: delta.surface, to: index)
                self.index.noteTabOrderChanged()
            } else {
                target.recomputeSpans()
            }
            // The record the pane shows for the surface: indexed again (new ids or a new pane),
            // with the state records of its ids.
            guard let shown = target.tabs.first(where: { $0.surface == delta.surface }) else { return .none }
            if shown !== tab { shown.update(delta.entity) }
            indexed(shown, in: target)
            return .none

        case .layoutChanged(let screen, let layout?, _):
            // `layout-delta-v1`: patch that one screen (I3).
            return applyLayoutChange(screen: screen, layout: layout)
        case .treeChanged, .layoutChanged:
            return .resync
        case .personalChanged:
            return .personal
        case .overflow:
            clearPresence()
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
            recordNotificationText(notification)
            if notifications.count > notificationLimit { notifications.removeFirst(notifications.count - notificationLimit) }
            // The daemon retains a marker only for an inactive target and
            // follows with `tree-changed`/`tab-changed`, which settle the state.
            return .none
        case .agentChanged(let status):
            if agents.apply(status) { tabsBySurface[status.surface]?.setAgent(status) }
            return .none
        case .agentPresenceChanged(let presence):
            tabsBySurface[presence.surface]?.setPresence(presence.activity == nil ? nil : presence)
            return .none

        case .sessionState(let item): session.apply(item, in: self); return .none
        case .terminalRegistryChanged, .bookmarksChanged, .historyChanged, .keybindingsChanged, .conversationChanged, .conversationTyping, .conversationDraft, .conversationLive, .conversationRunChanged, .cloudConversations,
             .terminalClipboardRead, .terminalClipboardReadCancelled, .unknown: // .unknown: the `apps-*` events of apps-v1
            sideEvents.deliver(event, envelope: envelope)
            return .none

        case .scrollChanged, .bell, .frontendProjectionChanged, .client:
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
        return .none
    }
}

extension DaemonStore {
    /// Drops every tab's agent presence (cx-gg84) when the store may have
    /// missed its clear: a lost connection, a daemon shutdown or dropped
    /// events. The daemon sends no presence in a snapshot; each agent's next
    /// hook event brings its presence back.
    func clearPresence() {
        for tab in tabsBySurface.values where tab.presence != nil {
            tab.setPresence(nil)
        }
    }
}
