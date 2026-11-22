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

    /// Starts the attempt now. `configuration.retryWake` is replaced by `wake`.
    public init(launcher: DaemonLauncher, configuration: DaemonConnection.Configuration,
                wake: RetryWake = RetryWake(owner: "DaemonService.retry local")) {
        self.launcher = launcher
        self.wake = wake
        var configuration = configuration
        configuration.retryWake = wake
        let fixed = configuration
        // task-owner: one attempt per launch; its requests carry the connection's deadlines
        attempt = Task.detached(priority: .userInitiated) {
            let connection = DaemonConnection(configuration: fixed, endpointProvider: launcher.endpointProvider)
            DaemonLaunchTimings.shared.mark("daemon.connect_start")
            do {
                let identity = try await connection.start()
                DaemonLaunchTimings.shared.mark("daemon.handshake_end")
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
