public import CmuxNextDaemon
import CmuxNextWakeups

/// "Restart cmux-tui to use new features" (plans/cmux-next/server-updates-DESIGN.md): after the
/// person confirmed, the local daemon is handed off to the bundled build. Terminals keep running
/// (their hosts are adopted); the connection reconnects by itself and the store records the new
/// daemon's handshake.
extension DaemonService {
    /// Restarts this app's local daemon and returns its successor's handshake; nil when this
    /// service cannot restart its daemon (remote, external binary, refused) or no successor
    /// connected within `timeout`.
    public func restartForUpdate(timeout: Duration = .seconds(30)) async -> DaemonIdentity? {
        guard let handOff = updateHandOff, let connection, let previous = identity else { return nil }
        guard await handOff(connection, previous) else { return nil }
        return await successor(of: previous, within: timeout)
    }

    /// The first handshake from another daemon process than `previous`, through the store's
    /// observed identity (no polling: an ``ObservedCondition``), or nil when `timeout` passes
    /// first (its ``MainDeadline``). The person confirmed the restart and waits for it: the
    /// re-reads and the bound are userBlocking.
    private func successor(of previous: DaemonIdentity, within timeout: Duration) async -> DaemonIdentity? {
        let store = store
        let successor: @MainActor () -> DaemonIdentity? = {
            guard let next = store.identity, next.pid != previous.pid || next.generation != previous.generation else { return nil }
            return next
        }
        await ObservedCondition(owner: "DaemonService.updateRestart", .userBlocking, on: mainWork)
            .until(timeout: timeout, deadlines: deadlines) { successor() != nil }
        return successor()
    }
}
