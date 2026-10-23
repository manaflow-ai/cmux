public import CmuxNextDaemon
import Foundation

// Kept tabs: dead terminal tabs with the workspace store's `relaunch` record, left by End
// Sessions, Keep Layout or parked by the classic migration (`park-tabs`). Each starts its new
// shell when a window shows its workspace, never at connect: a launch starts the terminals the
// person sees, not every terminal of every workspace (#17587, speed-of-sound 1). A request
// that needs a hidden kept tab's shell (the CLI's `send`, socket input, MCP's `terminal_*`
// tools, `terminal.wait`) starts it in the daemon by the same `restart-tab` path and waits for
// it (cmux-tui `Mux::live_surface_starting_kept_tab`), so every entrypoint sees the terminal
// these tabs draw as.
extension DaemonService {
    /// Starts the shells of `workspace`'s kept tabs in place (`restart-tab`), together. A window
    /// calls it whenever it shows the workspace and when the live tree of a connection lands; each
    /// tab starts once per connection, and one the daemon refuses stays dead with its Restart button.
    /// - Parameter workspace: A workspace a window shows now.
    public func startKeptTabs(in workspace: WorkspaceModel) {
        // The live tree of this owner only: the launch snapshot's surfaces, and a tree kept from the
        // owner before a restart until the new snapshot lands, carry another owner's numbers.
        guard let connection, store.isLoaded, store.generation.map({ $0 == identity?.generation }) ?? true,
              supports(DaemonCapabilities.shared.tabRestartKeptLayout) else { return }
        let surfaces = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            .filter { tab in
                tab.kind == .pty && tab.dead && tab.relaunch.map(startsWhenShown) == true && !startedKeptTabs.contains(tab.surface)
            }
            .map(\.surface)
        guard !surfaces.isEmpty else { return }
        startedKeptTabs.formUnion(surfaces)
        let logger = logger
        // task-owner: one restart per kept tab per connection (`startedKeptTabs`); each request has the connection's deadline
        Task { [weak self] in
            let refused = await connection.restartKeptTabs(surfaces)
            for line in refused.values { logger.error("kept tab did not start: \(line, privacy: .public)") }
            guard let self, self.connection === connection, !refused.isEmpty else { return }
            refusedKeptTabs.formUnion(refused.keys)
        }
    }

    /// Whether `tab` is a kept tab this service starts when it is shown: it draws as the terminal
    /// it becomes (the app shows its own intent at once), not as a dead tab and then a tab with no
    /// directory until its new shell runs. The daemon reports the record while the tab is dead or
    /// restarting and drops it once the new shell is in the tab. A kept tab whose start the daemon
    /// refused or whose new shell failed, or on a daemon that does not restart kept tabs, draws
    /// as dead. Observation-tracked (`refusedKeptTabs`, the identity, the tab's own fields).
    public func restartsKeptTab(_ tab: TabModel) -> Bool {
        guard let relaunch = tab.relaunch, startsWhenShown(relaunch) else { return false }
        // The daemon took the restart, then the new shell's launch failed: the tab is dead again.
        if tab.dead, tab.end?.reason == .restartFailed { return false }
        if refusedKeptTabs.contains(tab.surface) { return false }
        // Before the first handshake this Mac's daemon is expected to start it, so the launch
        // snapshot already draws it as the terminal it becomes.
        guard identity != nil else { return isLocal }
        return supports(DaemonCapabilities.shared.tabRestartKeptLayout)
    }

    /// A parked tab starts on show on any machine; an End Sessions, Keep Layout tab only on this
    /// Mac's daemon (Quit ends the local sessions; another machine's kept tabs keep their Restart button).
    private func startsWhenShown(_ relaunch: TabRelaunch) -> Bool {
        relaunch.onShow || isLocal
    }
}
