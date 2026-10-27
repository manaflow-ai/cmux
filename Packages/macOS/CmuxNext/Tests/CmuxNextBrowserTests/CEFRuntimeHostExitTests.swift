import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextTrace
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// p08-startup-046: when the Chromium Host ends, every page it showed shows the crash state of its
/// end, every reply still awaited fails, the crash log records the host once, and the runtime leaves
/// ready: nothing goes to the dead wire, and the next start (a new tab, or a sad tab's Reload) asks the
/// supervisor for a host again. Against a spy remote shim and a supervisor that reports host ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostExitTests {
    private static let killed = BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef)
    private static let page = URL(string: "https://example.com/")!

    @Test func aHostEndShowsTheCrashStateOnEveryPageAndRecordsOnlyTheHost() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let first = Self.tab(runtime, browser: 1)
        let second = Self.tab(runtime, browser: 2)
        var answers: [CEFContentSetting?] = []
        HostWire.state.withLock { $0.token = 41 }
        runtime.contentSetting(1, url: nil, kind: .camera) { answers.append($0) }

        let report = try #require(supervisor.onHostEnded, "the runtime does not follow the supervisor's host ends")
        report(Self.killed)

        #expect(first.state.processExit == Self.killed)
        #expect(second.state.processExit == Self.killed)
        #expect(first.browserID == nil && second.browserID == nil, "a page kept a browser of the dead host")
        #expect(answers == [nil], "a reply awaited from the dead host never ended")
        #expect(runtime.crashLog.records.map(\.processType) == ["chromium-host"], "one host end with 2 tabs wrote renderer records")
        #expect(runtime.crashLog.records.first?.reason == .killed)
        #expect(runtime.state == .idle, "the runtime says ready on a dead wire")
        #expect(runtime.shim == nil)
        #expect(runtime.awaitsHostRestart)
        #expect(HostWire.state.withLock { $0.detaches } == 1, "the remote shim kept the dead wire")
    }

    /// p01-process-085: each attach tells the supervisor its host's fork API, which that host's crash record names.
    @Test func theAttachTellsTheSupervisorItsHostsForkAPI() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: 2)
        defer { wire.close() }
        #expect(supervisor.forkAPIs == [2])
        supervisor.onHostEnded?(Self.killed)
        HostWire.state.withLock { $0.forkAPI = 3 }
        try await runtime.start(layout: nil, environment: [:], trigger: "tab")
        #expect(supervisor.forkAPIs == [2, 3])
    }

    /// p01-process-085: in host mode Chromium's log is the one the host's spawn names (`--log-file`, whose end the
    /// supervisor keeps in a crash record), so INITIALIZE names none: the runtime's `cef.log` would take its place.
    @Test func hostModeInitializesChromiumWithNoLogFileOfItsOwn() async throws {
        let (_, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        #expect(HostWire.state.withLock { $0.initializeLogFiles } == [""])
    }

    @Test func theNextStartAttachesTheNextHost() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        _ = Self.tab(runtime, browser: 1)
        supervisor.onHostEnded?(Self.killed)

        try await runtime.start(layout: nil, environment: [:], trigger: "tab")

        #expect(supervisor.asked == 2, "the start reused the dead host's attach")
        #expect(HostWire.state.withLock { $0.attached.count } == 2)
        #expect(runtime.state == .ready)
        #expect(!runtime.awaitsHostRestart)
        #expect(runtime.shim != nil)
    }

    /// The sad tab's Reload sends nothing while no host is attached: it re-attaches first, then loads the
    /// page on the new host.
    @Test func aSadTabsReloadWaitsForTheNextHostAndNothingReachesTheDeadWire() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        tab.load(Self.page)
        supervisor.onHostEnded?(Self.killed)

        tab.reload()
        #expect(tab.state.processExit == Self.killed, "the Reload went on before a host was attached")
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        #expect(supervisor.asked == 2, "the Reload did not attach the next host")
        // Joins the Reload's attach, so the test resumes once the runtime is ready again.
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where tab.state.processExit != nil { await Task.yield() }

        #expect(supervisor.asked == 2)
        #expect(HostWire.state.withLock { $0.deadWireOps } == 0, "an op went to the dead host's wire")
        #expect(tab.state.processExit == nil, "the page did not start loading again")
        #expect(tab.pendingURL == Self.page, "the page waits for its new browser with the wrong URL")
    }

    /// p14-energy-045: an Energy Saver edge while no host runs reaches nobody, so the next host's ready sends the
    /// app's current state again (a host starts with the saver off and the remote shim keeps only the last
    /// state it was given), and `debug.energy`'s `applied` is that host's answer.
    @Test func theNextHostGetsTheSaverStateOfAnEdgeWhileNoHostRan() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFForkFeatures.energySaverForkAPI)
        defer { wire.close() }
        let energy = runtime.wakeUps.energy
        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(HostWire.state.withLock { $0.energySaver } == [0, 1])
        #expect(CEFEnergySaver.applied(by: runtime))
        supervisor.onHostEnded?(Self.killed)

        energy.update(.normal)
        #expect(HostWire.state.withLock { $0.energySaver } == [0, 1], "an edge reached the shim while no host ran")
        #expect(!CEFEnergySaver.applied(by: runtime))

        try await runtime.start(layout: nil, environment: [:], trigger: "tab")

        #expect(HostWire.state.withLock { $0.energySaver } == [0, 1, 0], "the next host did not get the app's saver state")
        #expect(CEFEnergySaver.applied(by: runtime), "applied stayed the answer of the host that ended")
    }

    /// The disk reads before `cmux_shim_initialize` (profile root, last run's log, built-in extensions) run off
    /// the main thread, so the main thread's part of a host-mode start is the shim calls only.
    @Test func theStartReadsItsDiskInputsOffTheMainThread() async throws {
        let threads = PreparingThreads()
        let (runtime, supervisor, wire) = try await Self.startedRuntime { request in
            threads.onMain.withLock { $0.append(Thread.isMainThread) }
            return CEFStartInputs.prepare(request)
        }
        defer { wire.close() }
        #expect(threads.onMain.withLock { $0 } == [false], "the start read its inputs on the main thread")
        #expect(FileManager.default.fileExists(atPath: runtime.storage.root.path), "the start did not prepare the profile root")

        supervisor.onHostEnded?(Self.killed)
        try await runtime.start(layout: nil, environment: [:], trigger: "tab")
        #expect(threads.onMain.withLock { $0 } == [false, false], "the next host's start did not prepare its own inputs")
    }

    /// p09-observability-060: in host mode as in process, one renderer's end is one `cef.helper_exit` sample however
    /// many tabs it hosted: the host's shim marks the first browser of the end and the others share it.
    @Test func aRendererSharedByTwoTabsInTheHostIsOneHelperExitSample() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let trace = TraceRuntime(role: .app)
        let store = CEFPumpTests.store(on: trace)
        runtime.helperExits = CEFHelperExitMetric(metrics: Metrics(runtime: trace))
        let first = Self.tab(runtime, browser: 1)
        let second = Self.tab(runtime, browser: 2)

        runtime.handle(.renderTerminated(browser: 1, status: 2, code: Int(SIGSEGV), text: "", end: .first))
        runtime.handle(.renderTerminated(browser: 2, status: 2, code: Int(SIGSEGV), text: "", end: .shared))

        #expect(first.state.processExit?.reason == .crashed && second.state.processExit?.reason == .crashed)
        #expect(runtime.crashLog.records.map(\.processType) == ["renderer", "renderer"], "each tab logs its renderer")
        let samples = try #require(CEFPumpTests.histogram(.cefHelperExit, in: store))
        #expect(samples.count == 1 && samples.sum == 17, "one renderer crash, not one per tab")
    }

    @Test func inProcessAHostEndDoesNothing() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostWire.symbol), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        let tab = Self.tab(runtime, browser: 1)

        runtime.hostEnded(Self.killed)

        #expect(tab.state.processExit == nil)
        #expect(runtime.crashLog.records.isEmpty)
        #expect(runtime.state == .ready)
    }

    @Test func aSupervisorThatDoesNotReportEndsIsOnlyAttached() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))

        runtime.adoptHost(SilentHost())

        #expect(runtime.hostStart != nil)
    }

    // MARK: Crash page (p01-process-082)

    /// The host's end shows the sad tab in the exit turn, before the chrome's next render: that turn cleared
    /// the page's context, so a render one delivery later would leave a frame of the empty page area. It
    /// says Chromium stopped and offers Reload.
    @Test func aHostEndShowsTheCrashPageInTheExitTurn() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        let (status, area) = Self.statusViews(showing: tab)
        defer { withExtendedLifetime(area) {} }
        #expect(status.goneView.isHidden)

        supervisor.onHostEnded?(Self.hostKilled)

        #expect(!status.goneView.isHidden, "the crash page waited for the chrome's next render")
        #expect(status.shown.contains { $0 === status.goneView }, "the crash page is no page hole")
        #if DEBUG
        #expect(status.goneView.debugText.contains(Strings.pageGoneChromiumHostMessage))
        #expect(status.goneView.debugText.contains(Strings.pageGoneReload))
        #endif
    }

    /// RENDER_TERMINATED shows the same view in its own turn, with Chrome's sad tab message, only for the
    /// tab the chrome shows: a tab the chrome switched away from shows its crash page when shown again.
    @Test func aRendererEndShowsTheCrashPageOfTheShownTabInItsTurn() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        Self.rendererEndShowsTheCrashPage(runtime)
    }

    /// The in-process backend shows the same crash page in the same turn.
    @Test func inProcessARendererEndShowsTheCrashPageInItsTurn() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostWire.symbol), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        Self.rendererEndShowsTheCrashPage(runtime)
    }

    /// The page view drops all the dead host gave it in the exit turn: its context, cursor and the pane's
    /// cursors by the old host's browser ids (the next host numbers its browsers anew), and the focused field.
    @Test func aHostEndClearsWhatTheHostGaveThePageView() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        let page = tab.host.hostedPage()
        tab.host.pageCursorChanged(.builtIn(1), browser: 1)
        page.pageCursor = .builtIn(1)
        #if DEBUG
        page.applyTextInputState(ChromiumHostTextInputState(type: .password, selection: 0..<0))
        #endif

        supervisor.onHostEnded?(Self.hostKilled)

        #expect(page.contextID == 0)
        #expect(page.pageCursor == nil, "the dead page's cursor stayed over its sad tab")
        #expect(tab.host.pageCursors.isEmpty, "a cursor of the old host's browser id would show on the next host's")
        #if DEBUG
        #expect(page.textInput.state.type == .noField, "the dead host's focused field stayed focused")
        #endif
    }

    #if DEBUG
    /// The supervisor's path from a real host process to the runtime (task 080 conforms the same way): a
    /// stand-in host launched with the host launcher, SIGKILLed, its end mapped with `pageExit` and reported
    /// on main. The page shows the killed sad tab, and this process is still here to check it.
    @Test func aKilledHostProcessReachesThePageAsTheKilledSadTab() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)

        try await supervisor.killStandInHost()

        #expect(tab.state.processExit?.reason == .killed)
        #expect(tab.state.processExit?.codeDescription == "SIGKILL")
        #expect(runtime.crashLog.records.map(\.processType) == ["chromium-host"])
        #expect(runtime.state == .idle)
    }
    #endif

    // MARK: Fixtures

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-host-exit-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A runtime started in host mode over the spy remote shim, following `supervisor`'s host ends. It
    /// outlives the test: a pane's scheduled work reads it through an unowned reference.
    private static func startedRuntime(
        forkAPI: Int32 = 0,
        prepareInputs: (@Sendable (CEFStartInputs.Request) -> CEFStartInputs)? = nil
    ) async throws -> (CEFRuntime, ReportingHost, HostWire.Pipe) {
        HostWire.reset()
        HostWire.state.withLock { $0.forkAPI = forkAPI }
        let wire = try HostWire.Pipe()
        let supervisor = ReportingHost(controlFD: wire.fd)
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: scratch()))
        runtime.loadInProcess = { _ in .failure(.notEmbedded) }
        if let prepareInputs { runtime.prepareInputs = prepareInputs }
        runtime.adoptHost(supervisor)
        runtime.hostStart = CEFHostStart(supervisor: supervisor, open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: HostWire.symbol, expected: HostWire.abi)) } catch { return .failure(.shim(error)) }
        })
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        _ = Unmanaged.passRetained(runtime)
        return (runtime, supervisor, wire)
    }

    /// A Chromium Host's SIGKILL as the supervisor reports it (``ChromiumHostExit/pageExit``).
    private static let hostKilled = BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef, process: .chromiumHost)

    /// A chrome's status views over its page area (the views' parent, which the caller keeps: they hold it
    /// weakly), rendered once for `tab` as the chrome renders the tab it binds.
    private static func statusViews(showing tab: CEFTab) -> (PageStatusViews, NSView) {
        let status = PageStatusViews()
        let area = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        status.install(in: area) { tab }
        status.render(tab: tab)
        status.layout(over: area.bounds)
        return (status, area)
    }

    /// Two tabs; the chrome showed the first, then the second. The first's renderer end shows nothing here;
    /// the second's shows Chrome's sad tab in its turn, with no render between.
    private static func rendererEndShowsTheCrashPage(_ runtime: CEFRuntime) {
        let first = tab(runtime, browser: 1)
        let second = tab(runtime, browser: 2)
        let (status, area) = statusViews(showing: first)
        defer { withExtendedLifetime(area) {} }
        status.render(tab: second)

        runtime.handle(.renderTerminated(browser: 1, status: 2, code: Int(SIGSEGV), text: "", end: .first))
        #expect(first.state.processExit?.reason == .crashed)
        #expect(status.goneView.isHidden, "a tab the chrome no longer shows put up its crash page")

        runtime.handle(.renderTerminated(browser: 2, status: 2, code: Int(SIGSEGV), text: "", end: .first))
        #expect(!status.goneView.isHidden, "the crash page waited for the chrome's next render")
        #if DEBUG
        #expect(status.goneView.debugText.contains(Strings.pageGoneChromiumMessage))
        #endif
    }

    /// A tab in a pane of its own whose browser is `browser`.
    private static func tab(_ runtime: CEFRuntime, browser: Int32) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: browser)
        return tab
    }
}

/// Hands out the spy's wire on each request and reports host ends through ``onHostEnded``, which the
/// runtime sets.
@MainActor private final class ReportingHost: @MainActor ChromiumHostExitReporting {
    var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?
    private(set) var asked = 0
    private let controlFD: Int32

    init(controlFD: Int32) {
        self.controlFD = controlFD
    }

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        return ChromiumHostAttachment(controlFD: controlFD, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: ["en.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}

    func hostSaidHello() {}

    /// The fork API each attach read from its host (p01-process-085).
    private(set) var forkAPIs: [Int32] = []

    func hostRuns(forkAPI: Int32) {
        forkAPIs.append(forkAPI)
    }

    #if DEBUG
    /// Launches a stand-in host, SIGKILLs it, waits for its end off main and reports it as the supervisor
    /// does: mapped with `pageExit`, on main, nothing for a clean exit.
    func killStandInHost() async throws {
        let launcher = ChromiumHostLauncher()
        let handle = try await launcher.launch(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exec /bin/cat <&3 >&4"])
        launcher.kill(handle.pid)
        let ended = await launcher.exit(of: handle.pid)
        launcher.reap(handle.pid)
        Darwin.close(handle.readFD)
        Darwin.close(handle.writeFD)
        if let exit = ended.pageExit { onHostEnded?(exit) }
    }
    #endif
}

/// Whether each preparation of a start's inputs ran on the main thread.
private nonisolated final class PreparingThreads: Sendable {
    let onMain = Mutex<[Bool]>([])
}

/// Never attaches and reports nothing.
@MainActor private final class SilentHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// The remote dylib: the ABI id; attach (records the wire, says hello at once); detach; the reply token;
/// initialize (succeeds); the fork API version and `set_energy_saver` (recorded); `reload`, `load_url`,
/// `close` and `create_window`, which count the ops sent while no wire is attached. Every other export
/// does nothing and returns 0.
private nonisolated enum HostWire {
    private static let abiCString: StaticString = "host-exit-spy-abi"
    static let abi = "\(abiCString)"

    struct State {
        var attached: [Int32] = []
        var detaches = 0
        var live = false
        var deadWireOps = 0
        var token: UInt32 = 0
        /// What `cmux_shim_fork_api_version` returns.
        var forkAPI: Int32 = 0
        /// Each `cmux_shim_set_energy_saver` call's `enabled`.
        var energySaver: [Int32] = []
        /// Each `cmux_shim_initialize` call's log file, nil for NULL.
        var initializeLogFiles: [String?] = []
    }

    static let state = Mutex(State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    /// One op of the shim's C ABI: counted when no wire is attached.
    static func op() {
        state.withLock { if !$0.live { $0.deadWireOps += 1 } }
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafeRawPointer(HostWire.abiCString.utf8Start).assumingMemoryBound(to: CChar.self) }
        let attach: CEFRemoteShim.AttachFn = { control, _, _, context, hello in
            HostWire.state.withLock { state in
                state.attached.append(control)
                state.live = true
            }
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {
            HostWire.state.withLock { state in
                state.detaches += 1
                state.live = false
            }
        }
        let setReply: CEFRemoteShim.SetReplyFn = { _, _ in }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { HostWire.state.withLock { $0.token } }
        let initialize: @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<UnsafePointer<CChar>?>?,
            UnsafeMutableRawPointer?, CEFShimLibrary.ScheduleFn?, CEFShimLibrary.EventFn?, CEFShimLibrary.KeyFn?
        ) -> Int32 = { _, _, _, _, logFile, _, _, _, _, _, _, _, _ in
            let path = logFile.map { String(cString: $0) }
            HostWire.state.withLock { $0.initializeLogFiles.append(path) }
            return 1
        }
        let browserOp: @convention(c) (Int32) -> Void = { _ in HostWire.op() }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, _ in HostWire.op() }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            HostWire.op()
            return 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { HostWire.state.withLock { $0.forkAPI } }
        let setEnergySaver: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { enabled, _ in
            HostWire.state.withLock { $0.energySaver.append(enabled) }
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_energy_saver": unsafeBitCast(setEnergySaver, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_initialize": unsafeBitCast(initialize, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_reload", "cmux_shim_close": unsafeBitCast(browserOp, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_load_url": unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    /// A pipe whose read end stands in for the host's control socket.
    struct Pipe {
        let fd: Int32
        private let other: Int32

        init() throws {
            var fds: [Int32] = [-1, -1]
            guard Darwin.pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
            (fd, other) = (fds[0], fds[1])
        }

        func close() {
            Darwin.close(fd)
            Darwin.close(other)
        }
    }
}
