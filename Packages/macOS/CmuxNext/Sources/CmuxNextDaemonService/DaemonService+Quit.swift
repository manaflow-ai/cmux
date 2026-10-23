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
    ///   shell's directory, and the next launch starts a shell in each in
    ///   place when a window shows its workspace (`startKeptTabs`). Other
    ///   daemons remove the tabs.
    public func endSessionsAndStop(_ choice: QuitSessionsChoice) async -> [EndSessionsFailure] {
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
}
