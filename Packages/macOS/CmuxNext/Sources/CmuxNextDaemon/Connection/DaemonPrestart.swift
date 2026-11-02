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
private actor DaemonPrestartConnectionHolder {
    private var connection: DaemonConnection?
    private var cancelled = false

    func install(_ connection: DaemonConnection) async {
        if cancelled {
            await connection.closeAndWait()
        } else {
            self.connection = connection
        }
    }

    func cancel() async {
        cancelled = true
        guard let connection else { return }
        await connection.closeAndWait()
    }
}

public final class DaemonPrestart: Sendable {
    public typealias Outcome = Result<(DaemonConnection, DaemonIdentity), DaemonError>

    public let launcher: DaemonLauncher
    /// The connection's retry wake, which the owning service fires on app
    /// activation (the connection watches its socket through it too).
    public let wake: RetryWake
    private let attempt: Task<Outcome, Never>
    /// The bundled binary's build (`--version --json`), for the version
    /// handoff check: read from here, because a run begun only once the app
    /// started its services was still going when the connection came back.
    public let bundledBuild: Task<DaemonBuildStamp?, Never>

    /// Starts the attempt now. `configuration.retryWake` is replaced by `wake`.
    public init(launcher: DaemonLauncher, configuration: DaemonConnection.Configuration,
                wake: RetryWake = RetryWake(owner: "DaemonService.retry local")) {
        self.launcher = launcher
        self.wake = wake
        var configuration = configuration
        configuration.retryWake = wake
        let fixed = configuration
        // task-owner: one `--version --json` run per launch, bounded by its timeout
        bundledBuild = Task.detached(priority: .userInitiated) { try? await launcher.bundledBuild() }
        // task-owner: one attempt per launch; its requests carry the connection's deadlines
        let holder = DaemonPrestartConnectionHolder()
        attempt = Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler {
                let connection = DaemonConnection(configuration: fixed, endpointProvider: launcher.endpointProvider)
                await holder.install(connection)
                guard !Task.isCancelled else {
                    await holder.cancel()
                    return .failure(.launchFailed("prestart cancelled"))
                }
                DaemonLaunchTimings.shared.mark("daemon.connect_start")
                do {
                    let identity = try await connection.start()
                    DaemonLaunchTimings.shared.mark("daemon.handshake_end")
                    await connection.prefetchSnapshot()
                    return .success((connection, identity))
                } catch {
                    await connection.closeAndWait()
                    return .failure((error as? DaemonError) ?? .launchFailed(String(describing: error)))
                }
            } onCancel: {
                // concurrency-allow: cancellation cleanup is actor-isolated and joined by outcome teardown.
                Task { await holder.cancel() }
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
