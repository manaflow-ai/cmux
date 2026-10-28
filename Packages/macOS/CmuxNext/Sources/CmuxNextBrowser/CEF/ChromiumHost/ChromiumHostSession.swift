public import AppKit
import Darwin
import Observation

/// One Chromium page whose browser process runs in a host app of its own
/// (prototype behind `browserHost.helperPrototype`;
/// plans/cmux-next/cef-helper-app-DESIGN.md).
///
/// Owns the host process and the wire to it, and keeps what a restart needs:
/// the page's last committed URL and the view's geometry. When the host ends
/// (a Chromium CHECK, a crash, a kill), cmux keeps running; the page view
/// shows nothing until a new host gives its context, and
/// ``ChromiumHostRestartPolicy`` decides whether a new host starts with the
/// saved page.
///
/// Tests pass a ``ChromiumHostLaunching`` stand-in and a clock.
@MainActor @Observable
public final class ChromiumHostSession {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The host is starting: no context yet.
        case starting
        /// The host answered (`ready`).
        case running
        /// The host ended and does not start again until ``open(_:)``.
        case ended(String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var pid: Int32 = 0
    /// `cmux_cef_api_version()` the host reported.
    public private(set) var forkAPI: Int32 = 0
    public private(set) var contextID: UInt32 = 0
    /// The page's last committed main-frame URL: what a restarted host loads.
    public private(set) var url = ""
    public private(set) var title = ""
    /// How earlier hosts ended, oldest first.
    public private(set) var exits: [String] = []
    public private(set) var restarts = 0
    public private(set) var lastError: String?
    /// The page's pixels and input target; one view for every host the session starts.
    public let view = ChromiumHostPageView(frame: .zero)

    private let configuration: ChromiumHostConfiguration
    private let launcher: any ChromiumHostLaunching
    private let policy: ChromiumHostRestartPolicy
    private let now: () -> ContinuousClock.Instant
    private var connection: ChromiumHostConnection?
    private var startedAt: ContinuousClock.Instant?
    private var isFirstStart = true
    private var closing = false
    private var geometry: ChromiumHostGeometry?
    private var seq: UInt32 = 0
    private var pongs: [UInt32: CheckedContinuation<ChromiumHostFrame?, Never>] = [:]
    private var statsWaiters: [CheckedContinuation<ChromiumHostFrame?, Never>] = []
    private var tasks: [Task<Void, Never>] = []

    public init(configuration: ChromiumHostConfiguration) {
        self.configuration = configuration
        launcher = ChromiumHostLauncher()
        policy = ChromiumHostRestartPolicy()
        now = { ContinuousClock.now }
        wireView()
    }

    init(configuration: ChromiumHostConfiguration, launcher: any ChromiumHostLaunching,
         policy: ChromiumHostRestartPolicy = ChromiumHostRestartPolicy(), now: @escaping () -> ContinuousClock.Instant) {
        self.configuration = configuration
        self.launcher = launcher
        self.policy = policy
        self.now = now
        wireView()
    }

    private func wireView() {
        view.sink = { [weak self] frame in self?.send(frame) }
        view.onGeometry = { [weak self] geometry in
            self?.geometry = geometry
            self?.send(geometry.frame)
        }
    }

    /// Loads `url`, starting a host when none runs.
    public func open(_ url: String) {
        self.url = url
        closing = false
        if connection == nil {
            isFirstStart = true
            start()
        } else {
            send(ChromiumHostFrame(.navigate, payload: Array(url.utf8)))
        }
    }

    /// Ends the host on purpose (no restart).
    public func close() {
        closing = true
        send(ChromiumHostFrame(.quit))
    }

    /// SIGKILL to the host this session started (the crash check); its pid, or 0 when none runs.
    /// The pid stays this host's until hostEnded reaps it.
    @discardableResult
    public func killHost() -> Int32 {
        guard pid > 0, connection != nil else { return 0 }
        Darwin.kill(pid, SIGKILL)
        return pid
    }

    /// `count` round trips cmux -> host UI thread -> cmux, in microseconds.
    public func ping(count: Int) async -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count {
            seq &+= 1
            let id = seq
            let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var frame = ChromiumHostFrame(.ping, t0: sent)
            frame.seq = id
            let pong = await withCheckedContinuation { continuation in
                pongs[id] = continuation
                if !send(frame) { pongs.removeValue(forKey: id)?.resume(returning: nil) }
            }
            guard pong != nil else { break }
            samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sent) / 1_000)
        }
        return samples
    }

    /// The host's input timing: from each event's time in cmux to the host's
    /// `Send*Event` on its UI thread, in microseconds.
    public func hostInputStats() async -> [String: Int]? {
        let reply = await withCheckedContinuation { continuation in
            statsWaiters.append(continuation)
            if !send(ChromiumHostFrame(.stats)) { statsWaiters.removeLast().resume(returning: nil) }
        }
        guard let reply else { return nil }
        return ["events": Int(reply.v[0]), "p50_us": Int(reply.v[1]), "p95_us": Int(reply.v[2]),
                "p99_us": Int(reply.v[3]), "max_us": Int(reply.v[4]), "refused_frames": Int(reply.v[5])]
    }

    /// State for `debug.chromium_host`.
    public var report: [String: Any] {
        let phaseText: String
        switch phase {
        case .idle: phaseText = "idle"
        case .starting: phaseText = "starting"
        case .running: phaseText = "running"
        case .ended(let reason): phaseText = "ended: \(reason)"
        }
        return ["phase": phaseText, "pid": Int(pid), "fork_api": Int(forkAPI), "context_id": Int(contextID),
                "shown_context_id": Int(view.contextID), "url": url, "title": title, "restarts": restarts,
                "exits": exits, "error": lastError ?? ""]
    }

    // MARK: Lifecycle

    private func start() {
        let handle: ChromiumHostProcessHandle
        do {
            handle = try launcher.launch(executable: configuration.executable, arguments: configuration.arguments)
        } catch {
            phase = .ended("launch failed: \(error)")
            return
        }
        let connection = ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD)
        self.connection = connection
        pid = handle.pid
        phase = .starting
        startedAt = now()
        // The host reads these once Chromium is up; the wire holds them until then.
        connection.send(ChromiumHostFrame(.navigate, payload: Array(url.utf8)))
        if let geometry { connection.send(geometry.frame) }
        if view.window?.firstResponder === view { connection.send(ChromiumHostFrame(.focus, v: [1])) }
        let launcher = launcher
        tasks = [
            Task { [weak self] in
                for await frame in connection.frames { self?.handle(frame) }
                // The wire ended. A host that broke the protocol (a bad frame, a
                // flood) is still alive: end it, so its exit restarts it by the policy.
                // Its pid cannot be reused yet: an ended host stays a zombie until hostEnded reaps it.
                if connection.endedByProtocolError, let self, self.connection === connection { Darwin.kill(handle.pid, SIGKILL) }
            },
            Task { [weak self] in
                let exit = await launcher.exit(of: handle.pid)
                if let self {
                    self.hostEnded(exit, pid: handle.pid, connection: connection)
                } else {
                    launcher.reap(handle.pid)
                }
            },
        ]
    }

    private func handle(_ frame: ChromiumHostFrame) {
        switch frame.kind {
        case .ready:
            forkAPI = frame.v[0]
            phase = .running
        case .context:
            contextID = UInt32(bitPattern: frame.v[0])
            view.show(contextID: contextID)
        case .address:
            url = frame.text
        case .title:
            title = frame.text
        case .pong:
            pongs.removeValue(forKey: frame.seq)?.resume(returning: frame)
        case .statsReply:
            if !statsWaiters.isEmpty { statsWaiters.removeFirst().resume(returning: frame) }
        case .error:
            lastError = frame.text
        case .rendererGone:
            lastError = "renderer ended (status \(frame.v[0]))"
        default:
            break
        }
    }

    private func hostEnded(_ exit: ChromiumHostExit, pid ended: Int32, connection current: ChromiumHostConnection) {
        launcher.reap(ended)
        guard current === connection else { return }
        current.close()
        connection = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        contextID = 0
        view.show(contextID: 0)
        exits.append(exit.description)
        for waiter in pongs.values { waiter.resume(returning: nil) }
        pongs = [:]
        statsWaiters.forEach { $0.resume(returning: nil) }
        statsWaiters = []
        let ranFor = startedAt.map { now() - $0 } ?? .zero
        if closing {
            phase = .idle
        } else if policy.restarts(ranFor: ranFor, isFirstStart: isFirstStart) {
            restarts += 1
            isFirstStart = false
            start()
        } else {
            phase = .ended("ended twice within \(policy.quickEnd): \(exit)")
        }
    }

    /// Sends a frame to the running host; a host that stopped reading is
    /// ended (its exit restarts it by the policy). Its pid is not reused before
    /// hostEnded reaps it, so the kill reaches only this host.
    @discardableResult
    private func send(_ frame: ChromiumHostFrame) -> Bool {
        guard let connection else { return false }
        if connection.send(frame) { return true }
        if pid > 0 { Darwin.kill(pid, SIGKILL) }
        return false
    }
}
