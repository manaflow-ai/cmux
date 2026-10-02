import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Quit's end choices on the local daemon: stops this service's
    /// connection and reconnects first (the daemon's exit must not start a
    /// new one), then ends every terminal and stops the daemon
    /// (`shutdown-daemon end_terminals`, which waits for every terminal
    /// host). A failure is logged and the quit goes on: the terminals that
    /// did not end stay for the next launch.
    /// - End Everything closes every local workspace first, so the next
    ///   launch opens one new workspace.
    /// - End Sessions, Keep Layout on a daemon with
    ///   `end-terminals-keep-layout-v1` keeps the tabs: the daemon's
    ///   workspace store records each with its shell's directory, and the
    ///   next launch restarts a shell in each with the same splits and
    ///   ratios (`relaunchKeptLayoutIfNeeded`). Older daemons remove the tabs.
    func endSessionsAndStop(_ choice: QuitSessionsChoice) async {
        guard isLocal, choice.ends, let connection else { return }
        guard supports(DaemonCapabilities.shared.terminalReap) else {
            logger.error("end sessions: the daemon lacks \(DaemonCapabilities.shared.terminalReap, privacy: .public)")
            return
        }
        shutdownConnection()
        do {
            let ended = try await connection.endSessionsAndStop(deletingWorkspaces: choice == .endEverything,
                                                                keepingLayout: choice == .endKeepLayout)
            logger.info("end sessions: ended \(ended.endedTerminals) terminals, kept layout \(ended.keptLayout), daemon stopped")
        } catch {
            logger.error("end sessions failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// After End Sessions, Keep Layout: restarts a shell in every kept tab
    /// (a dead tab with the store's `relaunch` record), in its recorded
    /// directory, else home. The daemon prunes the record when the dead
    /// tab closes, so a later connect finds nothing to do.
    func relaunchKeptLayoutIfNeeded(_ connection: DaemonConnection) {
        guard isLocal, supports(DaemonCapabilities.shared.endTerminalsKeepLayout) else { return }
        let logger = logger
        let fallbackCwd = defaultCwd
        // task-owner: one-shot relaunch after connect; the daemon's records make it idempotent
        Task {
            do {
                let relaunched = try await connection.relaunchKeptTabs(fallbackCwd: fallbackCwd)
                if relaunched > 0 { logger.info("kept layout: restarted \(relaunched) terminals") }
            } catch {
                logger.error("kept layout relaunch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
