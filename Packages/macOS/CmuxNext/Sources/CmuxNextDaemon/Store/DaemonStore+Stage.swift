import Foundation

// Opening a script batch's stage, and what a held intent or a daemon event changes (StoreStage).
extension DaemonStore {
    /// Opens (or joins) the stage of a script batch run under `scope` (CLAUDE.md "Go past Chrome where
    /// cmux is scripted"): the batch's in-place changes show once, when every joined batch called
    /// ``StoreStageBatch/commit()``, or at the earliest deadline. Other workspaces and the person's own
    /// changes never wait.
    ///
    /// - Parameters:
    ///   - scope: The batch's command scope (`DaemonCommandScope.current` while it runs).
    ///   - deadline: When the stage commits by itself, on `clock`.
    ///   - clock: The deadline's clock, read for the deadline and slept on for it; tests pass one they
    ///     move by hand.
    /// - Returns: The batch's part of the stage.
    public func openStage<C: Clock>(for scope: DaemonCommandScope?, until deadline: C.Instant, clock: C) -> StoreStageBatch
    where C.Duration == Duration {
        let stage = self.stage.flatMap { $0.isOpen ? $0 : nil } ?? StoreStage(store: self)
        self.stage = stage
        return stage.join(scope: scope, until: deadline, clock: clock)
    }

    /// ``openStage(for:until:clock:)`` on the continuous clock (a control request's deadline).
    public func openStage(for scope: DaemonCommandScope?, until deadline: ContinuousClock.Instant) -> StoreStageBatch {
        openStage(for: scope, until: deadline, clock: ContinuousClock())
    }

    /// Commits the open stage when it holds an event at or below `sequence`.
    func commitStage(ifHolding sequence: UInt64?) {
        if let stage, stage.holds(through: sequence) { stage.commitAll() }
    }

    /// Records a read-your-writes wait for `sequence` until ``endAppliedWait(_:)``: the stage shows
    /// now what it holds at or below it, and holds no later event the wait needs (``awaitsNow(_:)``).
    public func beginAppliedWait(_ sequence: UInt64) {
        sequenceWaits[sequence, default: 0] += 1
        commitStage(ifHolding: sequence)
    }

    /// Ends a wait ``beginAppliedWait(_:)`` recorded.
    public func endAppliedWait(_ sequence: UInt64) {
        if let count = sequenceWaits[sequence], count > 1 { sequenceWaits[sequence] = count - 1 } else { sequenceWaits[sequence] = nil }
    }

    /// Whether a read-your-writes waiter needs `envelope` applied: its sequence is at or below a
    /// waited-for sequence, or it echoes a waited-for transaction.
    func awaitsNow(_ envelope: DaemonEventEnvelope) -> Bool {
        if let highest = sequenceWaits.keys.max(), envelope.sequence <= highest { return true }
        let echo = envelope.event.clientTransactionID
        return appliedWaiters.contains { waiter in
            (echo != nil && waiter.transaction == echo) || waiter.sequence.map { envelope.sequence <= $0 } == true
        }
    }

    /// The surface `event` names (a title, an exit, an agent's state, a tab delta).
    func stageSurface(of event: DaemonEvent) -> SurfaceID? {
        switch event {
        case .titleChanged(let surface, _), .surfaceResized(let surface, _), .surfaceExited(let surface),
             .scrollChanged(let surface, _, _), .bell(let surface):
            return surface
        case .tabAdded(let d), .tabClosed(let d), .tabRenamed(let d), .tabChanged(let d):
            return d.surface
        case .agentChanged(let status):
            return status.surface
        case .agentPresenceChanged(let presence):
            return presence.surface
        case .notification(let notification):
            return notification.surface
        default:
            return nil
        }
    }

    /// The screen `event` names (a layout, a screen, pane or tab delta).
    func stageScreen(of event: DaemonEvent) -> ScreenID? {
        switch event {
        case .layoutChanged(let screen, _, _):
            return screen
        case .screenAdded(let d), .screenClosed(let d), .screenRenamed(let d), .screenChanged(let d):
            return d.screen
        case .paneAdded(let d), .paneClosed(let d):
            return d.screen
        case .tabAdded(let d), .tabClosed(let d), .tabRenamed(let d), .tabChanged(let d):
            return d.screen
        default:
            return nil
        }
    }

    /// The workspaces an intent changes in place, by handle; nil for a kind a stage never holds
    /// (creates, splits, closes, sessions, groups, rows) or a target the records lack.
    func stageWorkspaces(of intent: Intent) -> Set<WorkspaceHandle>? {
        func ofSurface(_ surface: SurfaceID) -> WorkspaceHandle? {
            tab(surface: surface).flatMap { pane(holding: $0) }.flatMap { workspace(containing: $0.handle) }?.handle
        }
        switch intent {
        case .moveTab(let surface, let toPane, _):
            guard let from = ofSurface(surface), let to = workspace(containing: toPane)?.handle else { return nil }
            return [from, to]
        case .renameTab(let surface, _), .setTabPinned(let surface, _):
            return ofSurface(surface).map { [$0] }
        case .renameWorkspace(let key, _), .setWorkspaceColor(let key, _), .moveWorkspace(let key, _), .setWorkspaceGroup(let key, _), .placeWorkspace(let key, _, _):
            return workspace(key: key).map { [$0.handle] }
        case .renamePane(let pane, _):
            return workspace(containing: pane).map { [$0.handle] }
        case .renameScreen(let screen, _), .setScreenColor(let screen, _), .setScreenIcon(let screen, _), .setScreenPinned(let screen, _):
            return self.screen(screen).flatMap { index.workspace(holding: $0) }.map { [$0.handle] }
        case .setWorkspaceGroupCollapsed, .setTabGroupCollapsed, .setRowHeights, .createTab, .bindAgentSession, .splitPane,
             .createWorkspace, .closeTabs:
            return nil
        }
    }

    /// The workspaces a daemon event changes, by handle (empty: none of them, it never waits); nil
    /// for a lifecycle event, which commits a stage first.
    func stageReach(of event: DaemonEvent) -> Set<WorkspaceHandle>? {
        func ofSurface(_ surface: SurfaceID) -> Set<WorkspaceHandle> {
            tab(surface: surface).flatMap { pane(holding: $0) }.flatMap { workspace(containing: $0.handle) }.map { [$0.handle] } ?? []
        }
        switch event {
        case .connected, .disconnected, .daemonShutdown, .overflow:
            return nil
        case .workspaceAdded(let d), .workspaceClosed(let d), .workspaceRenamed(let d), .workspaceMoved(let d), .workspaceChanged(let d):
            return [d.workspace]
        case .screenAdded(let d), .screenClosed(let d), .screenRenamed(let d), .screenChanged(let d):
            return [d.workspace]
        case .paneAdded(let d), .paneClosed(let d):
            return [d.workspace]
        case .tabAdded(let d), .tabClosed(let d), .tabRenamed(let d), .tabChanged(let d):
            // A tab that moves between workspaces changes the one it leaves too.
            return Set([d.workspace]).union(ofSurface(d.surface))
        case .layoutChanged(let screen, _, _):
            return self.screen(screen).flatMap { index.workspace(holding: $0) }.map { [$0.handle] } ?? []
        case .titleChanged(let surface, _), .surfaceResized(let surface, _), .surfaceExited(let surface),
             .scrollChanged(let surface, _, _), .bell(let surface):
            return ofSurface(surface)
        default:
            return []
        }
    }
}
