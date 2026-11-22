public import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Quit's end choices on the local daemon: stops this service's
    /// connection and reconnects first (the daemon's exit must not start a
    /// new one), then ends every terminal and stops the daemon
    /// (`shutdown-daemon end_terminals`, which waits for every terminal
    /// host). Returns every step that failed (empty when all ended); the
    /// quit flow shows them and offers Retry, which calls this again on the
    /// same connection, or Quit Anyway, which leaves the terminals that did
    /// not end for the next launch.
    /// - End Everything closes every local workspace but Home first, so the
    ///   next launch opens Home only.
    /// - End Sessions, Keep Layout on a daemon with
    ///   `end-terminals-keep-layout-v1` and `tab-restart-kept-layout-v1`
    ///   keeps the tabs: the daemon's workspace store records each with its
    ///   shell's directory, and the next launch restarts a shell in each in
    ///   place (`relaunchKeptLayoutIfNeeded`). Other daemons remove the tabs.
    public func endSessionsAndStop(_ choice: QuitSessionsChoice) async -> [EndSessionsFailure] {
        guard isLocal, choice.ends, let connection = endingConnection ?? connection else { return [] }
        guard supports(DaemonCapability.terminalReap.rawValue) || endingConnection != nil else {
            logger.error("end sessions: the daemon lacks \(DaemonCapability.terminalReap.rawValue, privacy: .public)")
            return [EndSessionsFailure(step: .unsupported, message: DaemonCapability.terminalReap.rawValue)]
        }
        endingConnection = connection
        shutdownConnection()
        let ended = await connection.endSessionsAndStop(deletingWorkspaces: choice == .endEverything,
                                                        keepingLayout: choice == .endKeepLayout)
        if ended.failures.isEmpty {
            logger.info("end sessions: ended \(ended.endedTerminals) terminals, kept layout \(ended.keptLayout), daemon stopped")
        } else {
            for failure in ended.failures {
                logger.error("end sessions failed: \(String(describing: failure.step), privacy: .public): \(failure.message, privacy: .public)")
            }
        }
        return ended.failures
    }

    /// After End Sessions, Keep Layout: restarts a shell in every kept tab
    /// that does not wait for its first show (a dead tab with the store's
    /// `relaunch` record and no `onShow`: one whose terminal ran an agent; the
    /// rest start in `wakeParkedTabs`) in place (`restart-tab`),
    /// in its recorded directory, else home. One relaunch runs at a time per
    /// service (a reconnect while it runs does not start a second), and a
    /// closed connection cancels it.
    func relaunchKeptLayoutIfNeeded(_ connection: DaemonConnection) {
        guard keptLayoutRelaunch == nil else { return }
        guard isLocal, supports(DaemonCapability.endTerminalsKeepLayout.rawValue),
              supports(DaemonCapability.tabRestartKeptLayout.rawValue) else {
            // This daemon's kept tabs stay dead: they draw as dead.
            if keptTabRestarts != .none { keptTabRestarts = .none }
            return
        }
        let logger = logger
        keptLayoutRelaunch = Task { [weak self] in
            defer { self?.keptLayoutRelaunch = nil }
            do {
                let result = try await connection.relaunchKeptTabs()
                if result.relaunched > 0 { logger.info("kept layout: restarted \(result.relaunched) terminals") }
                for failure in result.failures {
                    logger.error("kept layout: a kept tab stays dead: \(failure, privacy: .public)")
                }
                let restarts = KeptTabRestarts.accepted(failed: result.failedSurfaces)
                if self?.keptTabRestarts != restarts { self?.keptTabRestarts = restarts }
            } catch {
                logger.error("kept layout relaunch failed: \(String(describing: error), privacy: .public)")
                // Nothing restarted: the kept tabs draw dead (a closed connection's next connect tries again).
                if !Task.isCancelled, self?.keptTabRestarts != KeptTabRestarts.none { self?.keptTabRestarts = .none }
            }
        }
    }

    /// Whether `tab` is a kept tab this launch restarts: it draws as the terminal it becomes (the
    /// app shows its own intent at once), not as a dead tab and then a tab with no directory until
    /// its new shell runs. The daemon reports the record while the tab is dead or restarting and
    /// drops it once the new shell is in the tab. A kept tab whose restart failed, or on a daemon
    /// that does not restart kept tabs, draws as dead. Observation-tracked (`keptTabRestarts`,
    /// the tab's own fields).
    public func restartsKeptTab(_ tab: TabModel) -> Bool {
        guard let relaunch = tab.relaunch else { return false }
        // The daemon took the restart, then the new shell's launch failed: the tab is dead again.
        if tab.dead, tab.end?.reason == .restartFailed { return false }
        // A parked tab starts when its workspace is shown (`wakeParkedTabs`).
        if relaunch.startsOnShow() { return supports(DaemonCapability.tabRestartKeptLayout.rawValue) }
        switch keptTabRestarts {
        case .none: return false
        case .expected: return true
        case .accepted(let failed): return !failed.contains(tab.surface)
        }
    }
}

/// Which kept tabs (`end-terminals-keep-layout-v1`) a daemon service restarts.
public enum KeptTabRestarts: Equatable, Sendable {
    /// None: a remote daemon, or one without `tab-restart-kept-layout-v1`.
    case none
    /// Every kept tab: the relaunch has not answered yet (before the first connect, or while it runs).
    case expected
    /// The relaunch asked for every kept tab; the daemon refused `failed`.
    case accepted(failed: Set<SurfaceID>)
}
