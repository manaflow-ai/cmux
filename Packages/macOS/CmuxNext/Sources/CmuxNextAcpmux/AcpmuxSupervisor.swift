public import CmuxNextWakeups
import CmuxNextCloud
import Foundation

/// Runs the app's acpmux daemon for as long as the app runs.
///
/// The daemon is a child started with `--exit-with-parent`, so it never
/// outlives the app, even after a crash or force quit. If it exits on its own
/// the supervisor restarts it after a backoff (one second, doubling, capped
/// at a minute). Readiness is event-driven: acpmux logs `listening on` once
/// its socket accepts connections.
///
/// ```swift
/// let supervisor = AcpmuxSupervisor(configuration: config)
/// await supervisor.start()
/// let path = await supervisor.readySocketPath()
/// ```
public actor AcpmuxSupervisor {
    private let configuration: AcpmuxLaunchConfiguration
    private let clock: any Clock<Duration>
    private var state: AcpmuxSupervisorState = .stopped
    private var subscribers: [UUID: AsyncStream<AcpmuxSupervisorState>.Continuation] = [:]
    private var child: ChildProcess?
    private var runTask: Task<Void, Never>?
    private var stopping = false

    /// Creates a supervisor.
    /// - Parameters:
    ///   - configuration: How to launch acpmux.
    ///   - clock: Times the restart backoff.
    public init(configuration: AcpmuxLaunchConfiguration, clock: any Clock<Duration> = ContinuousClock()) {
        self.configuration = configuration
        self.clock = clock
    }

    /// The daemon's socket path while it is running, else nil.
    public func readySocketPath() -> String? {
        if case .running = state { return configuration.socketPath }
        return nil
    }

    /// State changes, starting with the current state.
    public func states() -> AsyncStream<AcpmuxSupervisorState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AcpmuxSupervisorState>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuation.yield(state)
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.drop(id) } }
        return stream
    }

    private func drop(_ id: UUID) { subscribers[id] = nil }

    private func publish(_ s: AcpmuxSupervisorState) {
        state = s
        for c in subscribers.values { c.yield(s) }
    }

    /// Starts the daemon and keeps it running until ``stop()``.
    public func start() {
        guard runTask == nil else { return }
        stopping = false
        // task-owner: the supervisor's lifetime; stop() cancels it
        runTask = Task { await self.run() }
    }

    /// Stops the daemon (SIGTERM) and waits for it to exit.
    public func stop() async {
        stopping = true
        runTask?.cancel()
        runTask = nil
        if let child {
            child.terminate()
            _ = await child.waitForExit()
        }
        child = nil
        publish(.stopped)
    }

    private func run() async {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
        try? FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true)
        // wakeup-allow: one iteration per daemon lifetime; each ends on the child's exit, and restarts are paced by Backoff
        while !Task.isCancelled, !stopping {
            publish(.starting)
            let process = ChildProcess(
                executable: configuration.binary,
                arguments: configuration.arguments(parentPID: getpid()),
                environment: configuration.environment
            )
            child = process
            do {
                try process.start()
                // acpmux imports the login shell's environment (up to 15 s)
                // before it binds the socket.
                _ = try await process.firstLine(within: .seconds(45), label: "acpmux") { $0.contains("listening on") ? true : nil }
                publish(.running(pid: process.pid ?? 0))
                backoff.reset()
                let status = await process.waitForExit()
                if stopping { return }
                publish(.failed(reason: "acpmux exited (\(status))"))
            } catch {
                process.terminate()
                if stopping { return }
                publish(.failed(reason: String(describing: error)))
            }
            child = nil
            do {
                // concurrency-allow: async sleep on the supervisor's task, only after the daemon exited or failed to start
                try await backoff.wait(owner: "acpmux.restart", clock: clock)
            } catch {
                return
            }
        }
    }
}
