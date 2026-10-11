import CmuxNextDaemon
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
    ///   `end-terminals-keep-layout-v1` keeps the tabs: the daemon's
    ///   workspace store records each with its shell's directory, and the
    ///   next launch restarts a shell in each with the same splits and
    ///   ratios (`relaunchKeptLayoutIfNeeded`). Older daemons remove the tabs.
    func endSessionsAndStop(_ choice: QuitSessionsChoice) async -> [EndSessionsFailure] {
        guard isLocal, choice.ends, let connection = endingConnection ?? connection else { return [] }
        guard supports(DaemonCapabilities.shared.terminalReap) || endingConnection != nil else {
            logger.error("end sessions: the daemon lacks \(DaemonCapabilities.shared.terminalReap, privacy: .public)")
            return [EndSessionsFailure(step: .unsupported, message: DaemonCapabilities.shared.terminalReap)]
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
    /// (a dead tab with the store's `relaunch` record), in its recorded
    /// directory, else home. One relaunch runs at a time per service (a
    /// reconnect while it runs does not start a second), and a closed
    /// connection cancels it.
    func relaunchKeptLayoutIfNeeded(_ connection: DaemonConnection) {
        guard isLocal, keptLayoutRelaunch == nil, supports(DaemonCapabilities.shared.endTerminalsKeepLayout) else { return }
        let logger = logger
        let fallbackCwd = defaultCwd
        keptLayoutRelaunch = Task { [weak self] in
            defer { self?.keptLayoutRelaunch = nil }
            do {
                let result = try await connection.relaunchKeptTabs(fallbackCwd: fallbackCwd)
                if result.relaunched > 0 { logger.info("kept layout: restarted \(result.relaunched) terminals") }
                for failure in result.failures {
                    logger.error("kept layout: a kept tab stays dead: \(failure, privacy: .public)")
                }
            } catch {
                logger.error("kept layout relaunch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
