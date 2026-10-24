import Foundation

// Opening a script batch's stage, and what a held intent or a daemon event changes (StoreStage).
extension DaemonStore {
    /// Opens (or joins) the stage of a script batch run under `scope` (CLAUDE.md "Go past Chrome where
    /// cmux is scripted"): the batch's in-place changes show once, when it calls ``StoreStage/commit()``,
    /// or at `deadline`. Other workspaces and the person's own changes never wait.
    ///
    /// - Parameters:
    ///   - scope: The batch's command scope (`DaemonCommandScope.current` while it runs).
    ///   - deadline: When the stage commits by itself.
    ///   - clock: The deadline's clock; tests pass one they control.
    public func openStage(for scope: DaemonCommandScope?, until deadline: ContinuousClock.Instant,
                          clock: any Clock<Duration> = ContinuousClock()) -> StoreStage {
        let stage = self.stage.flatMap { $0.isOpen ? $0 : nil } ?? StoreStage(store: self)
        self.stage = stage
        stage.join(scope: scope, until: deadline, clock: clock)
        return stage
    }

    /// Commits the open stage when it holds an event at or below `sequence`.
    public func commitStage(ifHolding sequence: UInt64?) {
        if let stage, stage.holds(through: sequence) { stage.commit(all: true) }
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
        case .renameWorkspace(let key, _), .moveWorkspace(let key, _), .setWorkspaceGroup(let key, _), .placeWorkspace(let key, _, _):
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
