public import Foundation
import CmuxNextWakeups
import os

/// Runs `cnx-hostd` for the signed-in account and keeps it running: hands it
/// an access token and the app's acpmux endpoint over stdin at start and again
/// whenever it asks (`need_token`, `need_acpmux`: hostd asks when its token is
/// under a minute from expiry or refused, and when acpmux moved), folds its
/// status lines into a ``CnxHostState``, and restarts it with ``Backoff``
/// (1 s doubling to 60 s; reset after a minute up) when it exits. Nothing
/// here polls: every action follows a hostd line or a process exit.
///
/// Tokens never leave this actor except as hostd's stdin lines; nothing logs them.
public actor CnxHostSupervisor {
    /// What one run needs from the app.
    public struct Inputs: Sendable {
        public var launch: CnxHostLaunch
        /// The account's access token; `true` forces a refresh (hostd's was refused or expiring).
        public var accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
        /// The app's acpmux WebSocket and bearer token, nil while it has none.
        public var acpmux: @Sendable () async -> (url: URL, token: String)?
        /// hostd's stderr log (0600), nil for none.
        public var log: URL?
        /// The environment hostd's `HOME`, `PATH` and `TMPDIR` come from.
        public var inherited: [String: String]

        public init(launch: CnxHostLaunch, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
                    acpmux: @escaping @Sendable () async -> (url: URL, token: String)?, log: URL?,
                    inherited: [String: String] = ProcessInfo.processInfo.environment) {
            self.launch = launch
            self.accessToken = accessToken
            self.acpmux = acpmux
            self.log = log
            self.inherited = inherited
        }
    }

    /// Every state change, newest kept when the reader lags.
    public nonisolated let states: AsyncStream<CnxHostState>
    private let continuation: AsyncStream<CnxHostState>.Continuation
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.cnx-host")
    private var state = CnxHostState()
    private var run: Task<Void, Never>?
    private var process: CnxHostProcess?
    /// The last token sent: hostd asking again means it expired or was refused, so the next is forced fresh.
    private var lastToken: String?

    /// A run up this long (seconds) resets the backoff.
    static let healthyRun: TimeInterval = 60

    public init(clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        (states, continuation) = AsyncStream.makeStream(of: CnxHostState.self, bufferingPolicy: .bufferingNewest(1))
        self.clock = clock
        self.now = now
    }

    /// The current state.
    public var current: CnxHostState { state }

    /// Starts hostd for `inputs`, ending any run first.
    public func start(_ inputs: Inputs) async {
        await stop(phase: .connecting)
        guard FileManager.default.isExecutableFile(atPath: inputs.launch.executable.path) else {
            publish { $0.reset(to: .unavailable("cnx-hostd is not in this build")) }
            return
        }
        // task-owner: stored in `run`; stop() cancels it and waits for hostd to exit
        run = Task { await self.superviseLoop(inputs) }
    }

    /// Ends hostd and shows `phase`.
    public func stop(phase: CnxHostState.Phase = .off) async {
        let task = run
        run = nil
        task?.cancel()
        process?.stop()
        await task?.value
        publish { $0.reset(to: phase) }
    }

    /// Shows a phase without running hostd (for example, not signed in).
    public func show(_ phase: CnxHostState.Phase) {
        publish { $0.reset(to: phase) }
    }

    /// Runs hostd until stopped; each exit waits out ``Backoff`` before the next start.
    private func superviseLoop(_ inputs: Inputs) async {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
        // wakeup-allow: one turn per hostd exit (a process event), spaced by Backoff; it never polls
        repeat {
            let started = now()
            let reason = await runOnce(inputs)
            if Task.isCancelled { return }
            if now().timeIntervalSince(started) >= Self.healthyRun { backoff.reset() }
            logger.notice("cnx-hostd ended (\(reason, privacy: .public)); restarting after backoff")
            publish { $0.reset(to: .waiting(reason)) }
            do {
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                try await backoff.wait(owner: "cnx-hostd.restart", clock: clock)
            } catch {
                return
            }
        } while !Task.isCancelled // wakeup-allow: ends the restart loop above when stop() cancels it
    }

    /// One hostd process from start to exit; returns why it ended.
    private func runOnce(_ inputs: Inputs) async -> String {
        publish { $0.reset(to: .connecting) }
        let child = CnxHostProcess()
        do {
            try child.start(inputs.launch, environment: inputs.launch.environment(inherited: inputs.inherited), log: inputs.log)
        } catch {
            return "cnx-hostd did not start: \(error.localizedDescription)"
        }
        process = child
        defer { process = nil }
        logger.info("cnx-hostd started pid=\(child.pid ?? 0, privacy: .public) team=\(inputs.launch.teamID, privacy: .public)")
        // stop() cancels this task: closing hostd's stdin ends it, which ends the group.
        let status = await withTaskCancellationHandler {
            await watch(child, inputs: inputs)
        } onCancel: {
            child.stop()
        }
        if Task.isCancelled {
            _ = await child.waitForExit()
            return "stopped"
        }
        return "cnx-hostd exited with status \(status ?? -1)"
    }

    /// Waits for hostd to exit while pumping its events and feeding it tokens.
    private func watch(_ child: CnxHostProcess, inputs: Inputs) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await child.waitForExit() }
            group.addTask {
                await self.pump(child, inputs: inputs)
                return nil
            }
            group.addTask {
                await self.handOver(child, inputs: inputs)
                return nil
            }
            var exit: Int32?
            while let next = await group.next() {
                if let next {
                    exit = next
                    break
                }
            }
            group.cancelAll()
            if exit == nil { child.stop() }
            return exit
        }
    }

    /// Reads hostd's status lines until its stdout ends, answering its requests.
    private func pump(_ child: CnxHostProcess, inputs: Inputs) async {
        for await line in child.lines {
            guard let event = CnxHostEvent(line: line) else { continue }
            switch event {
            case .needToken:
                await sendToken(child, inputs: inputs)
            case .needAcpmux:
                await sendAcpmux(child, inputs: inputs)
            default:
                let at = now()
                publish { $0.apply(event, at: at) }
            }
        }
    }

    /// What hostd needs before its first connect: a token and the acpmux endpoint.
    private func handOver(_ child: CnxHostProcess, inputs: Inputs) async {
        lastToken = nil
        await sendToken(child, inputs: inputs)
        await sendAcpmux(child, inputs: inputs)
    }

    /// Sends the account's token. The account refreshes a token near expiry by
    /// itself; when it returns the token hostd already has (refused, or
    /// expiring within hostd's minute), the refresh is forced.
    private func sendToken(_ child: CnxHostProcess, inputs: Inputs) async {
        do {
            var token = try await inputs.accessToken(false)
            if token == lastToken { token = try await inputs.accessToken(true) }
            lastToken = token
            child.send(CnxHostLaunch.tokenLine(token))
        } catch {
            logger.error("no access token for cnx-hostd: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func sendAcpmux(_ child: CnxHostProcess, inputs: Inputs) async {
        guard let endpoint = await inputs.acpmux() else { return }
        child.send(CnxHostLaunch.acpmuxLine(url: endpoint.url, token: endpoint.token))
    }

    private func publish(_ change: (inout CnxHostState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        continuation.yield(next)
    }
}
