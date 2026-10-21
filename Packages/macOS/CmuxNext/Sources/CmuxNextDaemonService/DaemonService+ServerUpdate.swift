public import CmuxNextDaemon
import CmuxNextCompat
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
    /// observed identity (no polling), or nil when `timeout` passes first.
    private func successor(of previous: DaemonIdentity, within timeout: Duration) async -> DaemonIdentity? {
        let store = store
        let watch = Task { @MainActor () -> DaemonIdentity? in
            for await next in ObservationStream({ store.identity }) {
                if let next, next.pid != previous.pid || next.generation != previous.generation { return next }
            }
            return nil
        }
        // The deadline cancels the watch, whose stream then ends with nil.
        let deadline = DemandTimer(owner: "daemon.update.restart")
        deadline.schedule(after: timeout) { watch.cancel() }
        let found = await watch.value
        deadline.cancel()
        return found
    }
}
