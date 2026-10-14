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
        /// The app's browser hosts for streamed browser tabs; nil when this
        /// build has none (hostd then refuses `browser` as unavailable).
        public var browserHosts: (any CnxBrowserHosting)?
        /// This Mac's identity key, proved to phones that pinned it; nil: none.
        public var macIdentity: CnxMacIdentity?

        public init(launch: CnxHostLaunch, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
                    acpmux: @escaping @Sendable () async -> (url: URL, token: String)?, log: URL?,
                    inherited: [String: String] = ProcessInfo.processInfo.environment,
                    browserHosts: (any CnxBrowserHosting)? = nil, macIdentity: CnxMacIdentity? = nil) {
            self.macIdentity = macIdentity
            self.launch = launch
            self.accessToken = accessToken
            self.acpmux = acpmux
            self.log = log
            self.inherited = inherited
            self.browserHosts = browserHosts
        }
    }

    /// Every state change, newest kept when the reader lags.
    public nonisolated let states: AsyncStream<CnxHostState>
    private let continuation: AsyncStream<CnxHostState>.Continuation
    /// Pairing requests and sign-outs from phones (``CnxHostEvent/pairRequest(_:)``,
    /// ``CnxHostEvent/unpaired(phoneDeviceID:)``), in order.
    public nonisolated let pairing: AsyncStream<CnxHostEvent>
    private let pairingContinuation: AsyncStream<CnxHostEvent>.Continuation
    /// The last `devices` line: sent to each new hostd and on every change.
    private var devicesLine: Data?
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.cnx-host")
    private var state = CnxHostState()
    private var run: Task<Void, Never>?
    private var process: CnxHostProcess?
    /// The last token sent: hostd asking again means it expired or was refused, so the next is forced fresh.
    private var lastToken: String?
    /// Bumped by every start and stop; an older call that resumes late drops out.
    private var generation: UInt64 = 0

    /// hostd's exit status after the owner removed this Mac (`host.rs` `EXIT_REMOVED`).
    static let exitRemoved: Int32 = 78
    static let removedReason = "removed"

    /// A run up this long (seconds) resets the backoff.
    static let healthyRun: TimeInterval = 60

    public init(clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        (states, continuation) = AsyncStream.makeStream(of: CnxHostState.self, bufferingPolicy: .bufferingNewest(1))
        (pairing, pairingContinuation) = AsyncStream.makeStream(of: CnxHostEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.clock = clock
        self.now = now
    }

    /// The current state.
    public var current: CnxHostState { state }

    /// Starts hostd for `inputs`, ending any run first. A later start or stop that
    /// arrives while this one waits for the old run to end wins.
    public func start(_ inputs: Inputs) async {
        generation &+= 1
        let mine = generation
        await halt()
        guard generation == mine else { return }
        guard FileManager.default.isExecutableFile(atPath: inputs.launch.executable.path) else {
            publish { $0.reset(to: .unavailable("cnx-hostd is not in this build")) }
            return
        }
        // task-owner: stored in `run`; stop() cancels it and waits for hostd to exit
        run = Task { await self.superviseLoop(inputs) }
    }

    /// Ends hostd and shows `phase` (unless a start arrived meanwhile).
    public func stop(phase: CnxHostState.Phase = .off) async {
        generation &+= 1
        let mine = generation
        await halt()
        guard generation == mine else { return }
        publish { $0.reset(to: phase) }
    }

    /// Ends the current run and waits for its hostd to exit.
    private func halt() async {
        let task = run
        run = nil
        task?.cancel()
        process?.stop()
        await task?.value
    }

    /// Ends the live links of a phone the owner removed (hostd closes them at once).
    public func drop(phoneDeviceIDs: [String]) {
        for id in phoneDeviceIDs { process?.send(CnxHostLaunch.dropPhoneLine(id)) }
    }

    /// The phones this Mac approved: kept for each new hostd and sent to the
    /// running one now (a pairing link waiting on the user passes at once).
    public func setDevices(_ devices: CnxPairedDevices) {
        let line = CnxHostLaunch.devicesLine(devices)
        devicesLine = line
        process?.send(line)
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
            // The owner removed this Mac: hostd said so (`removed`, exit 78) and must stay
            // stopped; registering again would undo the removal.
            if state.phase == .removed || reason == Self.removedReason {
                logger.notice("this Mac was removed from the account's devices; cnx-hostd stays stopped")
                publish { $0.reset(to: .removed) }
                return
            }
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
        // A new hostd knows none of the old one's browser hosts.
        defer { if let hosts = inputs.browserHosts { Task { await hosts.stopAll() } } }
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
        if status == Self.exitRemoved { return Self.removedReason }
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
            case .pairRequest, .unpaired:
                pairingContinuation.yield(event)
            case let .needBrowser(request, tab, url):
                startBrowser(child, inputs: inputs, request: request, tab: tab, url: url)
            case let .browserStop(tab):
                if let hosts = inputs.browserHosts {
                    // task-owner: one stop per hostd request; the host's own exit reports back
                    Task { await hosts.stop(tab: tab) }
                }
            default:
                let at = now()
                publish { $0.apply(event, at: at) }
            }
        }
    }

    /// What hostd needs before its first connect: a token and the acpmux endpoint.
    private func handOver(_ child: CnxHostProcess, inputs: Inputs) async {
        lastToken = nil
        if let identity = inputs.macIdentity { child.send(CnxHostLaunch.macIdentityLine(identity)) }
        if let devicesLine { child.send(devicesLine) }
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

    /// Starts a browser host for hostd without holding up its other requests.
    private func startBrowser(_ child: CnxHostProcess, inputs: Inputs, request: UInt64, tab: String, url: String) {
        guard let hosts = inputs.browserHosts else {
            child.send(CnxHostLaunch.browserFailedLine(request: request, reason: "this build has no browser host"))
            return
        }
        let logger = logger
        // task-owner: one start per need_browser; it ends when the host listens or fails
        Task {
            do {
                let host = try await hosts.start(tab: tab, url: url) { [weak child] in
                    _ = child?.send(CnxHostLaunch.browserGoneLine(tab: tab))
                }
                logger.info("browser host for \(tab, privacy: .public) on port \(host.port, privacy: .public)")
                child.send(CnxHostLaunch.browserLine(request: request, port: host.port, secret: host.secret))
            } catch {
                logger.error("browser host for \(tab, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                child.send(CnxHostLaunch.browserFailedLine(request: request, reason: String(describing: error)))
            }
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
