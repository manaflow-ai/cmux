#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
public import AppKit
import CmuxNextWakeups
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
/// saved page. A host that could not start (``ChromiumHostExit/startFailure``)
/// is not restarted: a new one would fail the same way. Frames that a host
/// sent before it ended and that arrive after it ended change nothing.
///
/// Ending on purpose (``close()``) sends `quit` and SIGKILLs a host that has
/// not ended ``ChromiumHostFrame/quitLimit`` later (a hung UI thread never
/// reads `quit`); an ``open(_:)`` meanwhile waits for that exit and then
/// starts a new host. When cmux itself ends, the host reads EOF and ends
/// itself within the same limit (browser_host_main.mm).
///
/// Tests pass a ``ChromiumHostLaunching`` stand-in, a clock and a short quit limit.
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
    private let quitLimit: Duration
    private var connection: ChromiumHostConnection?
    private var startedAt: ContinuousClock.Instant?
    private var isFirstStart = true
    /// ``close()`` sent `quit` to the running host; its exit does not restart it.
    private var closing = false
    /// ``open(_:)`` came while the host was quitting: start a new host when it has ended.
    private var reopenWhenEnded = false
    /// SIGKILLs the quitting host at the quit limit; cancelled when it ends.
    @ObservationIgnored private let quitDeadline = DemandTimer(owner: "ChromiumHostSession.quit")
    private var geometry: ChromiumHostGeometry?
    private var seq: UInt32 = 0
    private var pongs: [UInt32: CheckedContinuation<ChromiumHostFrame?, Never>] = [:]
    /// Stats requests by `seq`, which the host's reply echoes.
    private var statsWaiters: [UInt32: CheckedContinuation<ChromiumHostFrame?, Never>] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(configuration: ChromiumHostConfiguration) {
        self.configuration = configuration
        launcher = ChromiumHostLauncher()
        policy = ChromiumHostRestartPolicy()
        now = { ContinuousClock.now }
        quitLimit = ChromiumHostFrame.quitLimit
        wireView()
    }

    init(configuration: ChromiumHostConfiguration, launcher: any ChromiumHostLaunching,
         policy: ChromiumHostRestartPolicy = ChromiumHostRestartPolicy(), now: @escaping () -> ContinuousClock.Instant,
         quitLimit: Duration = ChromiumHostFrame.quitLimit) {
        self.configuration = configuration
        self.launcher = launcher
        self.policy = policy
        self.now = now
        self.quitLimit = quitLimit
        wireView()
    }

    private func wireView() {
        view.sink = { [weak self] frame in self?.send(frame) }
        view.onGeometry = { [weak self] geometry in
            self?.geometry = geometry
            self?.send(geometry.frame)
        }
    }

    /// Loads `url`, starting a host when none runs. While the host quits
    /// (after ``close()``), a new host starts once it has ended.
    ///
    /// - Returns: false, with ``lastError`` set, when `url` is longer than a
    ///   frame carries (``ChromiumHostFrame/maxPayload``): the host would refuse
    ///   the frame and end, and every restart would load the same URL again.
    @discardableResult
    public func open(_ url: String) -> Bool {
        let navigate = ChromiumHostFrame(.navigate, payload: Array(url.utf8))
        guard ChromiumHostConnection.fits(navigate) else {
            lastError = "URL longer than \(ChromiumHostFrame.maxPayload) bytes"
            return false
        }
        self.url = url
        if connection == nil {
            closing = false
            isFirstStart = true
            start()
        } else if closing {
            reopenWhenEnded = true
        } else {
            send(navigate)
        }
        return true
    }

    /// Ends the host on purpose (no restart): sends `quit`, and SIGKILLs a
    /// host that has not ended ``ChromiumHostFrame/quitLimit`` later.
    public func close() {
        reopenWhenEnded = false
        guard let connection, !closing else { return }
        closing = true
        if !send(ChromiumHostFrame(.quit)) { return }  // send ended the host already
        let launcher = launcher, pid = pid
        // A deadline, not a wait: hostEnded cancels it.
        quitDeadline.schedule(after: quitLimit) { @MainActor [weak self] in
            guard let self, self.connection === connection else { return }
            launcher.kill(pid)
        }
    }

    /// SIGKILL to the host this session started (the crash check); its pid, or 0 when none runs.
    /// The pid stays this host's until hostEnded reaps it.
    @discardableResult
    public func killHost() -> Int32 {
        guard pid > 0, connection != nil else { return 0 }
        launcher.kill(pid)
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
            let pong: ChromiumHostFrame? = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<ChromiumHostFrame?, Never>) in
                    guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                    pongs[id] = continuation
                    if !send(frame) { pongs.removeValue(forKey: id)?.resume(returning: nil) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.pongs.removeValue(forKey: id)?.resume(returning: nil) }
            }
            guard pong != nil, !Task.isCancelled else { break }
            samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sent) / 1_000)
        }
        return samples
    }

    /// The host's input timing: from each event's time in cmux to the host's
    /// `Send*Event` on its UI thread, in microseconds.
    public func hostInputStats() async -> [String: Int]? {
        seq &+= 1
        let id = seq
        let reply: ChromiumHostFrame? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ChromiumHostFrame?, Never>) in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                statsWaiters[id] = continuation
                var frame = ChromiumHostFrame(.stats)
                frame.seq = id
                if !send(frame) { resumeStatsWaiter(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeStatsWaiter(id) }
        }
        guard let reply else { return nil }
        let v = reply.v
        let stats: [String: Int] = [
            "events": Int(v[0]), "p50_us": Int(v[1]), "p95_us": Int(v[2]),
            "p99_us": Int(v[3]), "max_us": Int(v[4]), "refused_frames": Int(v[5]),
        ]
        return stats
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
                // A cancelled iterator still gets the frames the stream holds, so a frame of
                // a host that has ended can come after hostEnded started the next host.
                for await frame in connection.frames { self?.handle(frame, from: connection) }
                // The wire ended. A host that broke the protocol (a bad frame, a
                // flood) is still alive: end it, so its exit restarts it by the policy.
                // Its pid cannot be reused yet: an ended host stays a zombie until hostEnded reaps it.
                if connection.endedByProtocolError, let self, self.connection === connection { launcher.kill(handle.pid) }
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

    /// Applies a frame of `source`; a frame of an earlier host (not the
    /// current connection) changes nothing.
    private func handle(_ frame: ChromiumHostFrame, from source: ChromiumHostConnection) {
        guard source === connection else { return }
        switch frame.kind {
        case .ready:
            forkAPI = frame.v[0]
            phase = .running
        case .context:
            contextID = UInt32(bitPattern: frame.v[0])
            view.show(contextID: contextID)
        case .address:
            // A host that quits (after close()) still reports its page; a reopen meanwhile set the URL
            // the next host loads, and the old page must not replace it.
            guard !closing else { return }
            url = frame.text
        case .title:
            title = frame.text
        case .pong:
            pongs.removeValue(forKey: frame.seq)?.resume(returning: frame)
        case .statsReply:
            statsWaiters.removeValue(forKey: frame.seq)?.resume(returning: frame)
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
        for waiter in statsWaiters.values { waiter.resume(returning: nil) }
        statsWaiters = [:]
        quitDeadline.cancel()
        let ranFor = startedAt.map { now() - $0 } ?? .zero
        if let failure = exit.startFailure {
            // The host could not start (no wire, no framework, an old fork, CefInitialize):
            // a new host would fail the same way, so none starts until ``open(_:)``.
            closing = false
            reopenWhenEnded = false
            phase = .ended(failure)
        } else if closing {
            closing = false
            if reopenWhenEnded {
                reopenWhenEnded = false
                isFirstStart = true
                start()
            } else {
                phase = .idle
            }
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
        guard let connection, ChromiumHostConnection.fits(frame) else { return false }
        if connection.send(frame) { return true }
        launcher.kill(pid)
        return false
    }

    private func resumeStatsWaiter(_ id: UInt32) {
        statsWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
#endif
