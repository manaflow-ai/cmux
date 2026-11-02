public import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import os

/// Runs `cmux-mobile-host` for the signed-in account and keeps it running: hands it
/// an access token and the app's acpmux endpoint over stdin at start and again
/// whenever it asks (`need_token`, `need_acpmux`: hostd asks when its token is
/// under a minute from expiry or refused, and when acpmux moved), folds its
/// status lines into a ``MobileHostState``, and restarts it with ``Backoff``
/// (1 s doubling to 60 s; reset after a minute up) when it exits. Nothing
/// here polls: every action follows a hostd line or a process exit.
///
/// Tokens never leave this actor except as hostd's stdin lines; nothing logs them.
public actor MobileHostSupervisor {
    /// What one run needs from the app.
    public struct Inputs: Sendable {
        public var launch: MobileHostLaunch
        /// The account's access token; `true` forces a refresh (hostd's was refused or expiring).
        public var accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
        /// The app's acpmux WebSocket and bearer token, nil while it has none.
        public var acpmux: @Sendable () async -> (url: URL, token: String)?
        /// hostd's stderr log (0600), nil for none.
        public var log: URL?
        /// The environment hostd's `HOME`, `PATH` and `TMPDIR` (and a DEBUG rig's machine id) come from.
        public var inherited: [String: String]
        /// The app's browser hosts for streamed browser tabs; nil when this
        /// build has none (hostd then refuses `browser` as unavailable).
        public var browserHosts: (any MobileHostBrowserHosting)?
        /// This Mac's identity key, proved to phones that pinned it; nil: none.
        public var macIdentity: MobileHostMacIdentity?
        /// The app's surface sources (phone tabs' simulators, `s<n>`, and the owner's Cloud
        /// desktops, `c~<machine>~<team>`); nil when this build streams neither (hostd then refuses `surface`).
        public var surfaceHosts: (any MobileHostSurfaceHosting)?
        /// Current new-architecture carriers and the plan's Cloud flag; fetched for every phone request, never cached here.
        public var cloudLinks: @Sendable () async -> MobileHostCloudLinks

        public init(launch: MobileHostLaunch, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
                    acpmux: @escaping @Sendable () async -> (url: URL, token: String)?, log: URL?,
                    inherited: [String: String] = ProcessInfo.processInfo.environment,
                    browserHosts: (any MobileHostBrowserHosting)? = nil, macIdentity: MobileHostMacIdentity? = nil,
                    surfaceHosts: (any MobileHostSurfaceHosting)? = nil,
                    cloudLinks: (@Sendable () async -> MobileHostCloudLinks)? = nil) {
            self.macIdentity = macIdentity
            self.surfaceHosts = surfaceHosts
            self.cloudLinks = cloudLinks ?? { MobileHostCloudLinks() }
            self.launch = launch
            self.accessToken = accessToken
            self.acpmux = acpmux
            self.log = log
            self.inherited = inherited
            self.browserHosts = browserHosts
        }
    }

    /// Every state change, newest kept when the reader lags.
    public nonisolated let states: AsyncStream<MobileHostState>
    private let continuation: AsyncStream<MobileHostState>.Continuation
    /// Pairing requests and sign-outs from phones (``MobileHostEvent/pairRequest(_:)``,
    /// ``MobileHostEvent/unpaired(phoneDeviceID:)``), in order.
    public nonisolated let pairing: AsyncStream<MobileHostEvent>
    private let pairingQueue = MobileHostQueue<MobileHostEvent>(capacity: 32)
    /// The newest `devices` line the app set (``setNewestDevices(_:)``): set at once on the caller's
    /// thread, so every hostd start and restart hands over the newest list, never one that an
    /// update still on its way to this actor would replace.
    private nonisolated let newestDevicesLine = Mutex<Data?>(nil)
    /// The last `phone_credentials` line (secrets, memory only): sent to each new hostd and on
    /// every change.
    private var phoneCredentialsLine: Data?
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.cmux-mobile-host")
    private var state = MobileHostState()
    private var run: Task<Void, Never>?
    private var process: MobileHostProcess?
    /// Bumped by every start and stop; an older call that resumes late drops out.
    private var generation: UInt64 = 0

    /// hostd's exit status after the owner removed this Mac (`host.rs` `EXIT_REMOVED`).
    static let exitRemoved: Int32 = 78
    static let removedReason = "removed"

    /// A run up this long (seconds) resets the backoff.
    static let healthyRun: TimeInterval = 60
    /// A run online this long (seconds) resets the backoff: it reached the
    /// service and served, so its end is not a crash loop.
    static let healthyOnline: TimeInterval = 5

    /// Whether a run that started at `started`, came online at `online` (nil:
    /// never) and ended at `ended` starts the next restart from the first delay.
    /// Only a minute-long run counted before, so a hostd killed every 13-45 s
    /// (a crash, a kill, an update) came back after 7, 16, 32 and 61 s, and
    /// phones waited that long for the Mac (termqa round 4).
    static func resetsBackoff(started: Date, online: Date?, ended: Date) -> Bool {
        if ended.timeIntervalSince(started) >= healthyRun { return true }
        guard let online else { return false }
        return ended.timeIntervalSince(online) >= healthyOnline
    }
    /// When the current run came online (nil until then).
    private var onlineSince: Date?

    public init(clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        (states, continuation) = AsyncStream.makeStream(of: MobileHostState.self, bufferingPolicy: .bufferingNewest(1))
        pairing = pairingQueue.stream
        self.clock = clock
        self.now = now
    }

    /// The current state.
    public var current: MobileHostState { state }

    /// Starts hostd for `inputs`, ending any run first. A later start or stop that
    /// arrives while this one waits for the old run to end wins.
    public func start(_ inputs: Inputs) async {
        generation &+= 1
        let mine = generation
        await halt()
        guard generation == mine else { return }
        guard FileManager.default.isExecutableFile(atPath: inputs.launch.executable.path) else {
            publish { $0.reset(to: .unavailable("cmux-mobile-host is not in this build")) }
            return
        }
        // task-owner: stored in `run`; stop() cancels it and waits for hostd to exit
        run = Task { await self.superviseLoop(inputs) }
    }

    /// Ends hostd and shows `phase` (unless a start arrived meanwhile).
    public func stop(phase: MobileHostState.Phase = .off) async {
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

    /// Refresh signaling and live endpoints after wake, without restarting hostd or its links.
    public func networkChanged() {
        process?.send(Data("{\"type\":\"network_changed\"}\n".utf8))
    }

    /// Ends the live links of a phone the owner removed (hostd closes them at once).
    public func drop(phoneDeviceIDs: [String]) {
        for id in phoneDeviceIDs { process?.send(MobileHostLaunch.dropPhoneLine(id)) }
    }

    /// The phones this Mac approved: kept at once for each new hostd, and sent to the running one
    /// (a pairing link waiting on the user passes at once).
    public nonisolated func setNewestDevices(_ devices: MobileHostPairedDevices) {
        let line = MobileHostLaunch.devicesLine(devices)
        newestDevicesLine.withLock { $0 = line }
        // task-owner: one hop to the running hostd; it sends the newest line, so hops that land out of order still end on it
        Task { await self.sendNewestDevices() }
    }

    /// The `devices` line a hostd started now gets.
    nonisolated func devicesForNextHostd() -> Data? { newestDevicesLine.withLock { $0 } }

    private func sendNewestDevices() {
        if let line = devicesForNextHostd() { process?.send(line) }
    }

    /// Each paired phone's own acpmux credential: kept for each new hostd and sent to the
    /// running one now (the phone's next acpmux channel presents it).
    public func setPhoneCredentials(_ credentials: [String: String]) {
        let line = MobileHostLaunch.phoneCredentialsLine(credentials)
        phoneCredentialsLine = line
        process?.send(line)
    }

    /// Shows a phase without running hostd (for example, not signed in).
    public func show(_ phase: MobileHostState.Phase) {
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
                logger.notice("this Mac was removed from the account's devices; cmux-mobile-host stays stopped")
                publish { $0.reset(to: .removed) }
                return
            }
            if Self.resetsBackoff(started: started, online: onlineSince, ended: now()) { backoff.reset() }
            logger.notice("cmux-mobile-host ended (\(reason, privacy: .public)); restarting after backoff")
            publish { $0.reset(to: .waiting(reason)) }
            do {
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                try await backoff.wait(owner: "cmux-mobile-host.restart", clock: clock)
            } catch {
                return
            }
        } while !Task.isCancelled // wakeup-allow: ends the restart loop above when stop() cancels it
    }

    /// One hostd process from start to exit; returns why it ended.
    private func runOnce(_ inputs: Inputs) async -> String {
        onlineSince = nil
        publish { $0.reset(to: .connecting) }
        let child = MobileHostProcess()
        do {
            try child.start(inputs.launch, environment: inputs.launch.environment(inherited: inputs.inherited), log: inputs.log)
        } catch {
            return "cmux-mobile-host did not start: \(error.localizedDescription)"
        }
        process = child
        defer { process = nil }
        // A new hostd knows none of the old one's browser hosts.
        defer { if let hosts = inputs.browserHosts { Task { await hosts.stopAll() } } }
        defer { if let sources = inputs.surfaceHosts { Task { await sources.stopAll() } } }
        logger.info("cmux-mobile-host started pid=\(child.pid ?? 0, privacy: .public) team=\(inputs.launch.teamID, privacy: .public)")
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
        return "cmux-mobile-host exited with status \(status ?? -1)"
    }

    private enum Watched: Sendable { case exited(Int32), drained, handedOver }

    /// Waits for hostd to exit and drains its final control lines before restarting.
    private func watch(_ child: MobileHostProcess, inputs: Inputs) async -> Int32? {
        let logger = logger
        let tokens = MobileHostTokenSupply(fetch: inputs.accessToken, send: { token in
            child.send(MobileHostLaunch.tokenLine(token))
        }, failed: { error in
            logger.error("no access token for cmux-mobile-host: \(String(describing: type(of: error)), privacy: .public)")
        })
        let result = await withTaskGroup(of: Watched.self) { group in
            group.addTask { .exited(await child.waitForExit()) }
            group.addTask {
                await self.pump(child, inputs: inputs, tokens: tokens)
                return .drained
            }
            group.addTask {
                await self.handOver(child, inputs: inputs, tokens: tokens)
                return .handedOver
            }
            var exit: Int32?
            var drained = false
            while let next = await group.next() {
                switch next {
                case let .exited(status): exit = status
                case .drained: drained = true
                case .handedOver: break
                }
                if exit != nil, drained { break }
            }
            group.cancelAll()
            if exit == nil { child.stop() }
            return exit
        }
        await tokens.stop()
        return result
    }

    /// Reads hostd's status lines until its stdout ends, answering its requests.
    private func pump(_ child: MobileHostProcess, inputs: Inputs, tokens: MobileHostTokenSupply) async {
        for await line in child.lines {
            guard let event = MobileHostEvent(line: line) else { continue }
            switch event {
            case .needToken:
                await tokens.request()
            case .needAcpmux:
                await sendAcpmux(child, inputs: inputs)
            case let .needCloudLinks(request):
                // task-owner: one bounded hostd request; sends only to the child that asked.
                // Looking up an install token must not hold up pairing or token control lines.
                Task {
                    let links = await inputs.cloudLinks()
                    if let line = MobileHostLaunch.cloudLinksLine(request: request, links: links) { child.send(line) }
                }
            case .pairRequest, .unpaired:
                await pairingQueue.send(event)
            case let .needBrowser(request, tab, url):
                startBrowser(child, inputs: inputs, request: request, tab: tab, url: url)
            case let .browserStop(tab):
                if let hosts = inputs.browserHosts {
                    // task-owner: one stop per hostd request; the host's own exit reports back
                    Task { await hosts.stop(tab: tab) }
                }
            case let .needSurface(request, tab):
                startSurface(child, inputs: inputs, request: request, tab: tab)
            case let .surfaceStop(tab):
                if let sources = inputs.surfaceHosts {
                    // task-owner: one stop per hostd request; the source's own end reports back
                    Task { await sources.stop(tab: tab) }
                }
            default:
                let at = now()
                if case .online = event, onlineSince == nil { onlineSince = at }
                publish { $0.apply(event, at: at) }
            }
        }
    }

    /// What hostd needs before its first connect: a token and the acpmux endpoint.
    private func handOver(_ child: MobileHostProcess, inputs: Inputs, tokens: MobileHostTokenSupply) async {
        if let identity = inputs.macIdentity { child.send(MobileHostLaunch.macIdentityLine(identity)) }
        if let devicesLine = devicesForNextHostd() { child.send(devicesLine) }
        if let phoneCredentialsLine { child.send(phoneCredentialsLine) }
        await tokens.request()
        await sendAcpmux(child, inputs: inputs)
    }

    /// Starts a browser host for hostd without holding up its other requests.
    private func startBrowser(_ child: MobileHostProcess, inputs: Inputs, request: UInt64, tab: String, url: String) {
        guard let hosts = inputs.browserHosts else {
            child.send(MobileHostLaunch.browserFailedLine(request: request, reason: "this build has no browser host"))
            return
        }
        let logger = logger
        // task-owner: one start per need_browser; it ends when the host listens or fails
        Task {
            do {
                let host = try await hosts.start(tab: tab, url: url) { [weak child] in
                    _ = child?.send(MobileHostLaunch.browserGoneLine(tab: tab))
                }
                logger.info("browser host for \(tab, privacy: .public) on port \(host.port, privacy: .public)")
                child.send(MobileHostLaunch.browserLine(request: request, port: host.port, secret: host.secret))
            } catch {
                logger.error("browser host for \(tab, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                child.send(MobileHostLaunch.browserFailedLine(request: request, reason: String(describing: error)))
            }
        }
    }

    /// Starts a simulator surface source for hostd without holding up its other requests.
    private func startSurface(_ child: MobileHostProcess, inputs: Inputs, request: UInt64, tab: String) {
        guard let sources = inputs.surfaceHosts else {
            child.send(MobileHostLaunch.surfaceFailedLine(request: request, reason: "this build does not stream simulators"))
            return
        }
        let logger = logger
        // task-owner: one start per need_surface; it ends when the source listens or fails
        Task {
            do {
                let source = try await sources.start(tab: tab) { [weak child] in
                    _ = child?.send(MobileHostLaunch.surfaceGoneLine(tab: tab))
                }
                logger.info("surface source for \(tab, privacy: .public) on port \(source.port, privacy: .public)")
                child.send(MobileHostLaunch.surfaceLine(request: request, port: source.port, secret: source.secret))
            } catch {
                logger.error("surface source for \(tab, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                child.send(MobileHostLaunch.surfaceFailedLine(request: request, reason: String(describing: error)))
            }
        }
    }

    private func sendAcpmux(_ child: MobileHostProcess, inputs: Inputs) async {
        guard let endpoint = await inputs.acpmux() else { return }
        child.send(MobileHostLaunch.acpmuxLine(url: endpoint.url, token: endpoint.token))
    }

    private func publish(_ change: (inout MobileHostState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        continuation.yield(next)
    }
}
