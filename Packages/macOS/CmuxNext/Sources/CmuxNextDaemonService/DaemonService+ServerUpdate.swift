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

    /// The bundled cmux-tui's build commit; nil when unknown (a remote or test service, or no
    /// `--version`). The first read is the launch's run; each later one runs `--version` again, so
    /// an app updated in place while it runs sees its new bundled build.
    public func bundledBuild() async -> String? {
        if let first = bundledCommit {
            bundledCommit = nil
            return await first.value
        }
        return await readBundledCommit?()
    }

    /// Hands the local daemon `identity` off to the bundled build without waiting for its successor
    /// (`QuietDaemonUpdate`). False when this service cannot (remote, external binary), the daemon
    /// refused, it was handed off for an update already, or the connection reached another daemon.
    func handOffForUpdate(_ identity: DaemonIdentity) async -> Bool {
        guard let handOff = updateHandOff, let connection, await connection.identity?.pid == identity.pid else { return false }
        return await handOff(connection, identity)
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
