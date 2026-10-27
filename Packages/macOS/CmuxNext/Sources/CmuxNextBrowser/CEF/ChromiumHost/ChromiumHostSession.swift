#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
public import AppKit
import CmuxNextWakeups
import Darwin
import Observation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError

/// One Chromium page whose browser process runs in a host app of its own
/// (prototype behind the feature `cefHelperHost`;
/// plans/cmux-next/cef-helper-app-DESIGN.md).
///
/// Owns the host process and the wire to it, and keeps what a restart needs:
/// the page's last committed URL and the view's geometry. When the host ends
/// (a Chromium CHECK, a crash, a kill), cmux keeps running; the page view
/// shows nothing until a new host gives its context, and
/// ``ChromiumHostRestartPolicy`` (Chrome's GPU crash budget) decides whether a
/// new host starts with the saved page. A host that died before its `ready`
/// is not restarted: a new one would die the same way, and the ended reason
/// says whether the host's code signature is valid. Frames that a host
/// sent before it ended and that arrive after it ended change nothing.
///
/// Ending on purpose (``close()``) sends `quit` and SIGKILLs a host that has
/// not ended ``ChromiumHostFrame/quitLimit`` later (a hung UI thread never
/// reads `quit`); an ``open(_:)`` meanwhile waits for that exit and then
/// starts a new host. When cmux itself ends, the host reads EOF and ends
/// itself within the same limit (browser_host_main.mm).
///
/// With an idle deadline (feature `chromiumHostIdleExit`), a host whose page
/// has not been live (its view in a window) for that long quits the same way,
/// as Chromium ends a service process nobody uses
/// (`mojo::Remote::reset_on_idle_timeout`, mojo/public/cpp/bindings/remote.h):
/// the browser process is most of the first Chromium tab's memory, and
/// nothing shows it. The page keeps its URL; its next show (or ``open(_:)``)
/// starts a new host under a stand-in (the page background, and the owner's
/// last picture of the page when it has one) until the new host's first context.
/// A hidden page's host that crashes is not restarted until the page shows, as
/// Chrome loads a crashed background tab again only when it is activated
/// (`NavigationController::LoadIfNecessary` from `Browser::OnActiveTabChanged`,
/// chrome/browser/ui/browser.cc).
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
        /// The host ended after its idle deadline, or ended while its page was hidden;
        /// the page's next show (or ``open(_:)``) starts a new one.
        case exitedIdle
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
    /// Hosts that ended after the idle deadline.
    public private(set) var idleExits = 0
    public private(set) var lastError: String?
    /// The page's pixels and input target; one view for every host the session starts.
    public let view = ChromiumHostPageView(frame: .zero)

    let configuration: ChromiumHostConfiguration
    private let launcher: any ChromiumHostLaunching
    private var policy: ChromiumHostRestartPolicy
    /// Checks the host's code signature when it could not start.
    private let signatureChecker: any ChromiumHostSignatureChecking
    private let quitLimit: Duration
    /// Told each connection the session opens (tests await its reader's end).
    private let connected: (ChromiumHostConnection) -> Void
    /// Takes each presentation report of the host (ChromiumHostSession+InputPresented.swift).
    let inputPresented: InputPresented
    let reportsInputPresented: ReportsInputPresented
    @ObservationIgnored var failedInputPresentations = 0
    private(set) var connection: ChromiumHostConnection?
    /// The current host sent `ready`: its Chromium context is initialized.
    private var saidHello = false
    /// ``close()`` sent `quit` to the running host; its exit does not restart it.
    private var closing = false
    /// ``open(_:)`` came while the host was quitting: start a new host when it has ended.
    private var reopenWhenEnded = false
    /// SIGKILLs the quitting host at the quit limit; cancelled when it ends.
    @ObservationIgnored private let quitDeadline = DemandTimer(owner: "ChromiumHostSession.quit")
    /// No live page this long quits the host; nil keeps it (the default).
    let idleExit: Duration?
    /// The owner's last picture of the page, shown while no host shows it.
    private let standInPicture: @MainActor () -> CGImage?
    /// Quits the host ``idleExit`` after its page stopped being live; cancelled by a show or its end.
    /// Background class: nothing shows the page while it waits.
    @ObservationIgnored private let idleDeadline: MainDeadline?
    /// The page's view is in a window.
    private(set) var isLive = false
    /// The quit in progress is the idle exit's: the host's end leaves ``Phase/exitedIdle``.
    private var idleQuitting = false
    private var geometry: ChromiumHostGeometry?
    // The measurement requests (ChromiumHostSession+Measure.swift).
    var seq: UInt32 = 0
    var pongs: [UInt32: OnceContinuation<ChromiumHostFrame?, OnceContinuationError>] = [:]
    /// Stats requests by `seq`, which the host's reply echoes.
    var statsWaiters: [UInt32: OnceContinuation<ChromiumHostFrame?, OnceContinuationError>] = [:]
    private var tasks: [Task<Void, Never>] = []
    /// ``start()`` launched a host that ``launched(_:)`` has not connected yet.
    private var launching = false
    /// ``close()`` came while the host launched: it quits as soon as it has connected.
    private var closeWhenLaunched = false

    /// - Parameters:
    ///   - idleExit: No live page this long quits the host (feature `chromiumHostIdleExit`,
    ///     param `idleExitAfter`), on the app's deadline scheduler; nil keeps it running.
    ///   - standInPicture: The page's last picture, shown while no host shows the page.
    ///   - inputPresented: Takes the host's presentation report of each input (the input latency tracker).
    ///   - reportsInputPresented: Takes whether the current host sends those reports.
    public convenience init(configuration: ChromiumHostConfiguration, idleExit: ChromiumHostIdleExit? = nil,
                            standInPicture: @escaping @MainActor () -> CGImage? = { nil },
                            inputPresented: @escaping InputPresented = { _, _ in },
                            reportsInputPresented: @escaping ReportsInputPresented = { _ in }) {
        self.init(configuration: configuration, launcher: ChromiumHostLauncher(),
                  idleExit: idleExit, standInPicture: standInPicture, inputPresented: inputPresented,
                  reportsInputPresented: reportsInputPresented)
    }

    init(configuration: ChromiumHostConfiguration, launcher: any ChromiumHostLaunching,
         policy: ChromiumHostRestartPolicy = ChromiumHostRestartPolicy(),
         signatureChecker: any ChromiumHostSignatureChecking = SecCodeChromiumHostSignatureChecker(),
         quitLimit: Duration = ChromiumHostFrame.quitLimit, idleExit: ChromiumHostIdleExit? = nil,
         standInPicture: @escaping @MainActor () -> CGImage? = { nil },
         inputPresented: @escaping InputPresented = { _, _ in },
         reportsInputPresented: @escaping ReportsInputPresented = { _ in },
         connected: @escaping (ChromiumHostConnection) -> Void = { _ in }) {
        self.configuration = configuration
        self.launcher = launcher
        self.policy = policy
        self.signatureChecker = signatureChecker
        self.quitLimit = quitLimit
        self.idleExit = idleExit?.after
        self.standInPicture = standInPicture
        self.connected = connected
        self.inputPresented = inputPresented
        self.reportsInputPresented = reportsInputPresented
        idleDeadline = idleExit.map {
            MainDeadline(owner: "ChromiumHostSession.idleExit", workClass: .background, scheduler: $0.deadlines)
        }
        wireView()
    }

    private func wireView() {
        // This wire stamps no input seq: no key comes back as KEY_UNHANDLED.
        view.sink = { [weak self] frame in
            _ = self?.send(frame)
            return nil
        }
        // The same stream as the key frames: an op follows the frames sent before it.
        view.textInputSink = { [weak self] op in _ = self?.send(ChromiumHostFrame(textInput: op)) }
        view.onGeometry = { [weak self] geometry in
            self?.geometry = geometry
            self?.send(geometry.frame)
        }
        view.onWindowChange = { [weak self] inWindow in self?.setLive(inWindow) }
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
        if launching {
            // The launching host loads `url` once it connects.
            closeWhenLaunched = false
        } else if connection == nil {
            closing = false
            startNew()
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
        idleQuitting = false
        idleDeadline?.cancel()
        view.removeStandIn()
        if launching {
            closeWhenLaunched = true
            return
        }
        if phase == .exitedIdle { phase = .idle }
        quit()
    }

    /// Sends `quit` to the running host and SIGKILLs it if it has not ended at the quit limit.
    private func quit() {
        guard let connection, !closing else { return }
        closing = true
        if !send(ChromiumHostFrame(.quit)) { return }  // send ended the host already
        let launcher = launcher, pid = pid
        // A deadline, not a wait: hostEnded cancels it.
        quitDeadline.scheduleOnMain(after: quitLimit) { [weak self] in
            guard let self, self.connection === connection else { return }
            launcher.kill(pid)
        }
    }

    /// The page's view entered a window (`live`) or left it. A page that stops being live arms
    /// the idle exit; a live page cancels it, and starts a new host when the last one ended idle.
    /// While the idle quit is in flight, hostEnded reads ``isLive`` when the host has ended.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        guard live else { return armIdleExit() }
        idleDeadline?.cancel()
        if phase == .exitedIdle { startNew() }
    }

    /// The idle deadline is set: the running host's page is not live.
    var isIdleExitArmed: Bool { idleDeadline?.isScheduled == true }

    /// No live page: the host quits at the idle deadline unless the page shows first.
    private func armIdleExit() {
        guard let idleExit, let idleDeadline, !isLive, connection != nil, !closing else { return }
        // The idle deadline itself, not a poll: a show, a close or the host's end cancels it.
        idleDeadline.schedule(after: idleExit) { [weak self] in self?.idleDeadlineReached() }
    }

    private func idleDeadlineReached() {
        guard !isLive, connection != nil, !closing else { return }
        idleQuitting = true
        if let picture = standInPicture() { view.showStandIn(picture) }
        quit()
    }

    /// A new host for the page (not a crash restart): under the page's stand-in when the last
    /// host ended after its idle deadline.
    private func startNew() {
        if phase == .exitedIdle, view.standIn == nil, let picture = standInPicture() { view.showStandIn(picture) }
        start()
    }

    /// SIGKILL to the host this session started (the crash check); its pid, or 0 when none runs.
    /// The pid stays this host's until hostEnded reaps it.
    @discardableResult
    public func killHost() -> Int32 {
        guard pid > 0, connection != nil else { return 0 }
        launcher.kill(pid)
        return pid
    }

    // MARK: Lifecycle

    /// Starts a host. The launcher spawns it off the main thread (ChromiumHostLauncher's spawn queue, as
    /// Chrome's process launcher thread does); the host's reader task awaits that launch, ``launched(_:)``
    /// connects the host, and the task then reads its frames. While it launches, ``open(_:)`` only changes
    /// the URL it loads, and ``close()`` ends it once it has connected.
    private func start() {
        fillPageBackground()
        phase = .starting
        launching = true
        let launcher = launcher, configuration = configuration
        tasks = [
            Task { [weak self] in
                let result: Result<ChromiumHostProcessHandle, any Error>
                do {
                    result = .success(try await launcher.launch(executable: configuration.executable, arguments: configuration.arguments))
                } catch {
                    result = .failure(error)
                }
                guard let started = self?.launched(result) else {
                    // Nobody owns this host any more: end it and free its pid and wire.
                    if self == nil, case .success(let orphan) = result { await launcher.discard(orphan) }
                    return
                }
                let (connection, pid) = started
                // A cancelled iterator still gets the frames the stream holds, so a frame of
                // a host that has ended can come after hostEnded started the next host.
                for await frame in connection.frames { self?.handle(frame, from: connection) }
                // The wire ended. A host that broke the protocol (a bad frame, a
                // flood) is still alive: end it, so its exit restarts it by the policy.
                // Its pid cannot be reused yet: an ended host stays a zombie until hostEnded reaps it.
                if connection.endedByProtocolError, let self, self.connection === connection { launcher.kill(pid) }
            },
        ]
    }

    /// Connects the host ``start()`` launched and starts waiting for its exit: its wire and pid. Nil, with the
    /// session ended, when it could not start.
    private func launched(_ result: Result<ChromiumHostProcessHandle, any Error>) -> (ChromiumHostConnection, pid_t)? {
        launching = false
        let handle: ChromiumHostProcessHandle
        switch result {
        case .success(let started):
            handle = started
        case .failure(let error):
            closeWhenLaunched = false
            view.removeStandIn()
            phase = .ended("launch failed: \(error)")
            return nil
        }
        let connection = ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD)
        self.connection = connection
        connected(connection)
        pid = handle.pid
        phase = .starting
        saidHello = false
        // The host reads these once Chromium is up; the wire holds them until then.
        connection.send(ChromiumHostFrame(.navigate, payload: Array(url.utf8)))
        if let geometry { connection.send(geometry.frame) }
        if view.window?.firstResponder === view { connection.send(ChromiumHostFrame(.focus, v: [1])) }
        // The page view's NSTextInputClient answers from the state the host pushes (task 044).
        connection.send(ChromiumHostFrame(.textInputWatch, v: [1]))
        let launcher = launcher, executable = configuration.executable, checker = signatureChecker
        tasks.append(
            Task { [weak self] in
                let exit = await launcher.exit(of: handle.pid)
                guard let self else { return launcher.reap(handle.pid) }
                // A host that could not start: macOS kills one whose signature is broken before its first
                // line runs, so the ended reason says what the check of the signature on disk found.
                var signature = ChromiumHostSignatureCheck.notChecked
                if ChromiumHostRestartPolicy.cannotStart(exit, saidHello: self.saidHello, cause: self.endCause) {
                    signature = await Self.checkSignature(of: executable, with: checker)
                }
                self.hostEnded(exit, signature: signature, pid: handle.pid, connection: connection)
            })
        if closeWhenLaunched {
            closeWhenLaunched = false
            close()
        } else {
            armIdleExit()
        }
        return (connection, handle.pid)
    }

    /// Applies a frame of `source`; a frame of an earlier host (not the
    /// current connection) changes nothing.
    private func handle(_ frame: ChromiumHostFrame, from source: ChromiumHostConnection) {
        guard source === connection else { return }
        switch frame.kind {
        case .ready:
            forkAPI = frame.v[0]
            saidHello = true
            phase = .running
            reportsInputPresented(frame.reportsInputPresented)
        case .context:
            contextID = UInt32(bitPattern: frame.v[0])
            view.show(contextID: contextID)
            if contextID != 0 { view.removeStandIn() }
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
        case .textInputState:
            if let state = ChromiumHostTextInputState(frame: frame) { view.applyTextInputState(state) }
        case .inputPresented:
            takeInputPresented(frame)
        default:
            break
        }
    }

    /// Why the current host ends, as this session knows it: a quit (close or the idle exit) is cmux's own end
    /// and spends nothing of the budget.
    private var endCause: ChromiumHostEndCause { closing ? .quit : .crash }

    /// Reads and hashes the host's code on disk, off the main thread.
    @concurrent nonisolated private static func checkSignature(
        of executable: URL, with checker: any ChromiumHostSignatureChecking
    ) async -> ChromiumHostSignatureCheck {
        checker.check(executable)
    }

    private func hostEnded(_ exit: ChromiumHostExit, signature: ChromiumHostSignatureCheck, pid ended: Int32,
                           connection current: ChromiumHostConnection) {
        launcher.reap(ended)
        guard current === connection else { return }
        current.close()
        connection = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        contextID = 0
        view.show(contextID: 0)
        reportsInputPresented(false)
        // The focused field ended with the host, and any composition in it.
        view.applyTextInputState(ChromiumHostTextInputState())
        fillPageBackground()
        exits.append(exit.description)
        for waiter in pongs.values { waiter.resume(returning: nil) }
        pongs = [:]
        for waiter in statsWaiters.values { waiter.resume(returning: nil) }
        statsWaiters = [:]
        quitDeadline.cancel()
        idleDeadline?.cancel()
        let endedIdle = idleQuitting
        idleQuitting = false
        switch policy.hostEnded(exit, saidHello: saidHello, cause: endCause, signature: signature) {
        case .notCounted:
            closing = false
            if endedIdle {
                idleExits += 1
                phase = .exitedIdle
                // Shown again while it quit (and still shown), or opened: the new host starts under the stand-in.
                if reopenWhenEnded || isLive {
                    reopenWhenEnded = false
                    startNew()
                }
            } else if reopenWhenEnded {
                reopenWhenEnded = false
                start()
            } else {
                phase = .idle
            }
        case .restart where idleExit != nil && !isLive:
            // A hidden page's host crashed: nothing shows it, so the next show starts its host.
            phase = .exitedIdle
        case .restart:
            restarts += 1
            start()
        case .ended(let crashes):
            view.removeStandIn()
            phase = .ended("ended \(crashes) times within \(policy.forgiveAfter): \(exit)")
        case .cannotStart(let failure):
            // No wire, no framework, an old fork, CefInitialize, or a death before `ready`:
            // a new host would fail the same way, so none starts until ``open(_:)``.
            view.removeStandIn()
            phase = .ended(failure.description)
        }
    }

    /// Sends a frame to the running host at once (a full socket queues it in
    /// the connection's outbox); a host whose wire broke (the outbox is full,
    /// the socket failed) is ended (its exit restarts it by the policy). Its pid is not reused before
    /// hostEnded reaps it, so the kill reaches only this host.
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool {
        guard let connection, ChromiumHostConnection.fits(frame) else { return false }
        if connection.send(frame) { return true }
        launcher.kill(pid)
        return false
    }

    /// The page view shows the theme's page background (`PageBackground.themeARGB` of its pane) wherever
    /// the host's pixels are not: while a host starts, restarts or has ended, instead of a hole onto
    /// whatever is behind the pane. The host sends no page color on the wire yet, so the fill stays under
    /// the page once its context shows.
    private func fillPageBackground() {
        view.backgroundFill = PageBackground.cgColor(argb: PageBackground.themeARGB(in: view))
    }
}
#endif
