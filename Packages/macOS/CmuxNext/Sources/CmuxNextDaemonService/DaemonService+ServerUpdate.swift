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
    /// connected. `timeout` bounds the wait with no sign of the successor: each restore report of
    /// the starting successor (a long cleanup, a compaction) starts it again, so a successor that
    /// restores for minutes is waited for, and one that never reports gives up after `timeout`.
    public func restartForUpdate(timeout: Duration = .seconds(30)) async -> DaemonIdentity? {
        guard let handOff = updateHandOff, let connection, let previous = identity else { return nil }
        guard await handOff(connection, previous) else { return nil }
        return await successor(of: previous, idle: timeout)
    }

    /// The first handshake from another daemon process than `previous`, through the store's
    /// observed identity (no polling), or nil when `idle` passes with neither a handshake nor a
    /// restore report.
    private func successor(of previous: DaemonIdentity, idle: Duration) async -> DaemonIdentity? {
        let store = store
        let watch = Task { @MainActor () -> DaemonIdentity? in
            for await next in ObservationStream({ store.identity }) {
                if let next, next.pid != previous.pid || next.generation != previous.generation { return next }
            }
            return nil
        }
        // The deadline cancels the watch, whose stream then ends with nil; each restore report re-arms it.
        let deadline = DemandTimer(owner: "daemon.update.restart", clock: startupClock)
        deadline.schedule(after: idle) { watch.cancel() }
        // task-owner: ended below once the watch returns; event-driven (Observation of the restore reports)
        let progress = Task { @MainActor [weak self] in
            for await _ in ObservationStream({ self?.restoreReportsSeen ?? 0 }).dropFirst() {
                deadline.schedule(after: idle) { watch.cancel() }
            }
        }
        let found = await watch.value
        progress.cancel()
        deadline.cancel()
        return found
    }
}
