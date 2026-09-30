import CmuxNextDaemon

extension DaemonService {
    /// Quit's "End All Sessions" on the local daemon: stops this service's
    /// connection and reconnects first (the daemon's exit must not start a
    /// new one), then ends every terminal and stops the daemon
    /// (`shutdown-daemon end_terminals`, which waits for every terminal
    /// host). A failure is logged and the quit goes on: the terminals that
    /// did not end stay for the next launch.
    func endSessionsAndStop() async {
        guard isLocal, let connection else { return }
        guard supports(DaemonCapabilities.terminalReap) else {
            logger.error("end sessions: the daemon lacks \(DaemonCapabilities.terminalReap, privacy: .public)")
            return
        }
        shutdownConnection()
        do {
            let ended = try await connection.endSessionsAndStop()
            logger.info("end sessions: ended \(ended) terminals, daemon stopped")
        } catch {
            logger.error("end sessions failed: \(String(describing: error), privacy: .public)")
        }
    }
}
