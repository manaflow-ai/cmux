public import CmuxNextLaunch
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
public final class DaemonPrestart: Sendable {
    public typealias Outcome = Result<(DaemonConnection, DaemonIdentity), DaemonError>

    public let launcher: DaemonLauncher
    /// The connection's retry wake, which the owning service fires on app
    /// activation (the connection watches its socket through it too).
    public let wake: RetryWake
    private let attempt: Task<Outcome, Never>
    /// The bundled binary's build commit (`--version`), for the version
    /// handoff check: read from here, because a run begun only once the app
    /// started its services was still going when the connection came back.
    public let bundledCommit: Task<String?, Never>
    /// The session's launch snapshot, read and decoded off the main thread meanwhile
    /// (``LaunchRead``): the first window draws the last layout from it.
    public let launchSnapshot: LaunchRead<LaunchSnapshot.Found>
    /// Where the launch snapshot's path is recorded: the snapshot above was found through it, and
    /// the service started with this prestart records each handshake's path through it too, so
    /// the read and the record never use two places.
    public let launchSnapshotLocation: LaunchSnapshotLocation

    /// Starts the attempt and the launch snapshot's read now. `configuration.retryWake` is replaced by `wake`.
    /// - Parameter launchSnapshotLocation: Where the snapshot's path is recorded (tests pass
    ///   their own defaults); the service started with this prestart uses it as well.
    public init(launcher: DaemonLauncher, configuration: DaemonConnection.Configuration,
                wake: RetryWake = RetryWake(owner: "DaemonService.retry local"),
                launchSnapshotLocation: LaunchSnapshotLocation = LaunchSnapshotLocation()) {
        self.launcher = launcher
        self.wake = wake
        self.launchSnapshotLocation = launchSnapshotLocation
        let (session, stateDirectory) = (launcher.configuration.session, launcher.configuration.stateDirectory)
        launchSnapshot = LaunchRead("launch_snapshot", readOnMain: { DaemonLaunchTimings.shared.mark($0) }) {
            LaunchSnapshot.find(session: session, stateDirectory: stateDirectory, location: launchSnapshotLocation)
        }
        var configuration = configuration
        configuration.retryWake = wake
        let fixed = configuration
        // task-owner: one `--version` run per launch, bounded by its timeout
        bundledCommit = Task.detached(priority: .userInitiated) { try? await launcher.bundledBuildCommit() }
        // task-owner: one attempt per launch; its requests carry the connection's deadlines
        attempt = Task.detached(priority: .userInitiated) {
            let connection = DaemonConnection(configuration: fixed, endpointProvider: launcher.endpointProvider)
            DaemonLaunchTimings.shared.mark("daemon.connect_start")
            do {
                let identity = try await connection.start()
                DaemonLaunchTimings.shared.mark("daemon.handshake_end")
                await connection.prefetchSnapshot()
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
