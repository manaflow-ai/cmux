import CmuxNextControl
import CmuxNextDaemon
import CmuxNextWakeups

extension AppControl {
    /// `after: "sync"` (plans/cmux-next/state-ownership.md 4.3): one round
    /// trip to the local daemon, then the event sequence routed before its
    /// reply. The daemon replies to a mutation only after committing it and
    /// emits its events before later replies on this connection, so the
    /// snapshot that reflects this sequence includes every write another
    /// client (the CLI talking to the daemon) finished before the request.
    func registerSyncBarrier(_ router: ControlRouter, daemon: DaemonService) {
        let offline = MiscHandlerStrings.daemonOffline
        router.registerSyncBarrier { [weak daemon, work = mainWork] in
            // The CLI's barrier: its read of the connection is automation work.
            guard let connection = await work.apply(.automation, owner: "control.sync_barrier", { daemon?.connection }) else {
                throw ControlError(code: "unavailable", message: offline)
            }
            _ = try await connection.request(IdentifyRequest())
            guard let sequence = await connection.eventSequence() else {
                throw ControlError(code: "unavailable", message: offline)
            }
            return sequence
        }
    }
}
