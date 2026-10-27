import CmuxNextWakeups
import Foundation

/// The local daemon's first connect attempt, begun at the top of `main` so
/// it overlaps AppKit's own start instead of following it. Process start to
/// `applicationDidFinishLaunching` alone took about 150 ms on a loaded
/// machine, and the attempt only started after that method returned; this
/// attempt is usually connected (handshake done) before the first window
/// exists, so terminals drawn from the launch snapshot attach at once.
///
/// It runs off the main thread (a detached task) and never touches the
/// store: `DaemonStartup.connect(first:)` takes its outcome as the first
/// attempt, and the connection's events stay buffered until the store runs
/// it. A failed attempt is reported like any other failed first connect and
/// retried by the same loop.
///
/// It records the launch's connect milestones (``DaemonConnectMarks``): `daemon.connect_started` when `main` begins
/// it and `daemon.spawned` when its `server ensure` started a daemon (cold); its `daemon.identified` (the handshake)
/// and `daemon.snapshot_received` (the prefetched snapshot) are kept until the service attaches this connection.
/// The spawn runs on ``ProcessRunner``'s launcher queue, never the main thread.
public final class DaemonPrestart: Sendable {
    public typealias Outcome = Result<(DaemonConnection, DaemonIdentity), DaemonError>

    public let launcher: DaemonLauncher
    /// The connection's retry wake, which the owning service fires on app
    /// activation (the connection watches its socket through it too).
    public let wake: RetryWake
    /// The launch's connect milestones, each sent once; the service attaches its connection through them.
    public let marks: DaemonConnectMarks
    private let attempt: Task<Outcome, Never>
    /// The bundled binary's build commit (`--version`), for the version
    /// handoff check: read from here, because a run begun only once the app
    /// started its services was still going when the connection came back.
    public let bundledCommit: Task<String?, Never>
    /// The app's daemon features its hellos carry (``ClientHelloIdentity/features``), for the connections after
    /// this one and for `features.list`.
    public let featureHello: DaemonFeatureHello?

    /// Starts the attempt now. `configuration.retryWake` is replaced by `wake`. `marks` gets the connect
    /// milestones (the app passes one that sends them to its launch timings).
    public init(launcher: DaemonLauncher, configuration: DaemonConnection.Configuration,
                wake: RetryWake = RetryWake(owner: "DaemonService.retry local"),
                marks: DaemonConnectMarks = DaemonConnectMarks()) {
        self.launcher = launcher
        self.wake = wake
        self.marks = marks
        featureHello = configuration.clientHello?.features
        marks.mark(.connectStarted)
        var configuration = configuration
        configuration.retryWake = wake
        let fixed = configuration
        // task-owner: one `--version` run per launch, bounded by its timeout
        bundledCommit = Task.detached(priority: .userInitiated) { try? await launcher.bundledBuildCommit() }
        // task-owner: one attempt per launch; its requests carry the connection's deadlines
        attempt = Task.detached(priority: .userInitiated) {
            let connection = DaemonConnection(configuration: fixed, endpointProvider: marks.endpointProvider(of: launcher))
            DaemonLaunchTimings.shared.mark("daemon.connect_start")
            do {
                let identity = try await connection.start()
                DaemonLaunchTimings.shared.mark("daemon.handshake_end")
                marks.mark(.identified, of: connection)
                await connection.prefetchSnapshot(onReceived: { marks.mark(.snapshotReceived, of: connection) })
                return .success((connection, identity))
            } catch {
                await connection.close()
                return .failure((error as? DaemonError) ?? .launchFailed(String(describing: error)))
            }
        }
    }

    /// The attempt's outcome (waits for it).
    public func outcome() async -> Outcome {
        await attempt.value
    }

    /// Cancels an attempt nobody will use.
    public func cancel() {
        attempt.cancel()
    }
}
