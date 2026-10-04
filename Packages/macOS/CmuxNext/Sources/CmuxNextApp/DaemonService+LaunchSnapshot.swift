import CmuxNextControl
import CmuxNextDaemon

// The launch snapshot (`launch-snapshot-v1`, plans/cmux-next/cmux-tui-contract.md):
// the last layout drawn before the first connection, then replaced in place;
// and the first connect begun in `main` with the remembered daemon socket.
extension DaemonService {
    /// Applies the daemon's launch snapshot as a provisional tree, so the
    /// first frame shows the last layout instead of the connecting state.
    /// The path comes from the last handshake; a missing, stale or
    /// unreadable file shows nothing. The file is small (the daemon caps it
    /// at 8 MiB) and local, and reading it replaces waiting for the daemon,
    /// so it is read before the first window.
    func showLaunchSnapshot(session: String) {
        guard let path = launchSnapshotLocation.path(session: session),
              let snapshot = LaunchSnapshot.load(path: path, session: session) else { return }
        store.applyProvisional(snapshot: snapshot.tree)
        launchSnapshotWindows = snapshot.windows
        DebugTimings.markLaunch("launch_snapshot_applied")
    }

    /// Records the snapshot path the local daemon reported, for the next launch.
    func rememberLaunchSnapshot(_ identity: DaemonIdentity) {
        guard let session = launchSnapshotSession, identity.session == session else { return }
        launchSnapshotLocation.record(identity.launchSnapshotPath, session: session)
    }

    /// Begins the local daemon's first connect attempt off the main thread,
    /// at the top of `main`, so it overlaps AppKit's start; `start(launch:…
    /// prestart:)` takes it over. Nil when the launcher cannot be made (the
    /// later `start` reports why).
    nonisolated static func prestart(launch: LaunchIdentity, terminalEnvironment: [String: String],
                                     terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String]) -> DaemonPrestart? {
        guard let launcher = try? DaemonLauncher.forApp(tag: launch.tag, terminalEnvironment: terminalEnvironment) else { return nil }
        return DaemonPrestart(launcher: launcher, configuration: DaemonConnection.Configuration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: true))
    }

    /// Records the local daemon's socket for the next launch
    /// (`DaemonSocketMemory`), so it connects without `server status`.
    func rememberSocket(_ identity: DaemonIdentity, connection: DaemonConnection) async {
        guard let session = launchSnapshotSession, identity.session == session,
              let path = await connection.endpoint?.socketPath else { return }
        DaemonSocketMemory().record(path, session: session)
    }

    /// Waits for the first connection (or for startup to give up): an event,
    /// not a retry, so terminals drawn from the snapshot attach at once.
    func firstConnection() async {
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func resumeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
