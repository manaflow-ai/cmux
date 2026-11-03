import CmuxNextControl
import CmuxNextDaemon

extension AppControl {
    /// `after: "sync"` (plans/cmux-next/state-ownership.md 4.3): one round
    /// trip to the local daemon, then the event sequence routed before its
    /// reply. The daemon replies to a mutation only after committing it and
    /// emits its events before later replies on this connection, so the
    /// snapshot that reflects this sequence includes every write another
    /// client (the CLI talking to the daemon) finished before the request.
    func registerSyncBarrier(_ router: ControlRouter, daemon: DaemonService) {
        let offline = MiscHandlerStrings.daemonOffline
        router.registerSyncBarrier { [weak daemon] in
            guard let connection = await MainActor.run(body: { daemon?.connection }) else {
                throw ControlError(code: "unavailable", message: offline)
            }
            // No wall clock (#32724): the daemon answers `identify` before its connection's queue,
            // so only load delays it, and load must not fail a request. The ask ends with its
            // reply or the connection's end; the heartbeat ends a local connection only when the
            // daemon process is gone.
            _ = try await connection.request(IdentifyRequest(), timeout: nil)
            guard let sequence = await connection.eventSequence() else {
                throw ControlError(code: "unavailable", message: offline)
            }
            return sequence
        }
    }
}
