@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// Host mode (``BrowserBackend/host``, task 015 of plans/cmux-next/chrome-parity/p01-process.md):
/// `CEFRuntime.start` takes the Chromium Host's wire from the supervisor, opens and attaches the
/// remote shim and initializes through it. It never runs the in-process load (no
/// `CEFLoadedLibrary`, no framework), never prepares NSApp and starts no pump. The remote shim's
/// ABI identity is checked as the in-process shim's is. Against a fake supervisor and a spy shim.
@MainActor @Suite(.serialized) struct CEFRuntimeBackendTests {
    @Test func hostModeNeverBuildsTheInProcessLibrary() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let supervisor = FakeSupervisor(controlFD: wire.fd)
        let runtime = Self.runtime(supervisor: supervisor)

        try await runtime.start(layout: nil, environment: [:], trigger: "test")

        #expect(RemoteSpy.inProcessLoads == 0, "host mode built a CEFLoadedLibrary")
        #expect(runtime.state == .ready)
        #expect(supervisor.asked == 1)
        #expect(RemoteSpy.attachedFDs == [wire.fd])
        #expect(runtime.pump == nil, "host mode started the message pump")
        #expect(runtime.layout == nil, "host mode resolved the framework layout")
        #expect(RemoteSpy.prepareApplicationCalls == 0)
        #expect(RemoteSpy.initializeFrameworkPaths == [""], "host mode sent a framework path to initialize")
        #expect(runtime.forkAPIVersion == RemoteSpy.forkAPI, "the fork version is the host's, read after attach")
        #expect(runtime.displayObservation != nil, "host mode left the pane host views without display changes")
        #expect(RemoteSpy.detachCalls == 0)
    }

    /// Task 034: host mode makes no ``CEFPumpTimer``, gives initialize no schedule callback (so the shim
    /// sets no `external_message_pump`), never asks for the fork's delayed work and never calls
    /// `cmux_shim_do_work`, quit's drain included (done check 3: no `CefDoMessageLoopWork` in the app).
    @Test func hostModeMakesNoPumpTimerAndNeverPumps() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let timers = PumpTimerCounter()
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd), makePumpTimer: { _ in timers.make() })

        try await runtime.start(layout: nil, environment: [:], trigger: "test")

        #expect(timers.made == 0, "host mode made a CEFPumpTimer")
        #expect(runtime.inProcessPump == nil, "host mode started the message pump")
        #expect(RemoteSpy.initializeScheduleCallbacks == [false], "host mode gave initialize a schedule callback")
        #expect(RemoteSpy.scheduleDelayedCalls == 0, "host mode asked for the fork's delayed work")

        await runtime.shutdown(timeout: .milliseconds(1))
        #expect(RemoteSpy.doWorkCalls == 0, "host mode ran a pump pass")
        #expect(timers.made == 0)
    }

    /// The control case, through the real in-process initialize: it makes the pump's one timer, asks
    /// for the fork's delayed work once and gives initialize the schedule callback, without which the
    /// shim sets no `external_message_pump` and nothing pumps in-process Chromium. Initialize fails in
    /// the spy, so the start stops before its ready hooks (child monitor, window guard).
    @Test func theInProcessStartMakesOnePumpAndGivesInitializeTheScheduleCallback() async throws {
        RemoteSpy.reset()
        RemoteSpy.initializeResult = 0
        let shim = try CEFShimLibrary.resolving(RemoteSpy.symbol)
        let root = Self.scratch()
        let library = CEFLoadedLibrary(shim: shim, shimABI: RemoteSpy.abi,
                                       layout: CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root),
                                       locale: CEFLocale(locale: CEFLocale.fallback, acceptLanguages: CEFLocale.fallback),
                                       loadDuration: .zero)
        let timers = PumpTimerCounter()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: root), makePumpTimer: { _ in timers.make() })
        runtime.loadInProcess = { _ in
            RemoteSpy.inProcessLoads += 1
            return .success(library)
        }

        await Self.expectFailed(runtime)

        #expect(RemoteSpy.inProcessLoads == 1)
        #expect(RemoteSpy.prepareApplicationCalls == 1)
        #expect(RemoteSpy.initializeScheduleCallbacks == [true], "the in-process initialize got no schedule callback")
        #expect(RemoteSpy.scheduleDelayedCalls == 1)
        #expect(timers.made == 1)
        #expect(runtime.inProcessPump != nil)
    }

    /// The attach points the remote shim's REPLY frames at the runtime's one reply table: the token
    /// read right after an async call resolves the call that awaits it, whether the REPLY comes
    /// before or after the await (task 018).
    @Test func aReplyFromTheHostResolvesTheTokenItsCallAwaits() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        let host = try #require(runtime.hostStart)
        let sink = try #require(RemoteSpy.replySink)
        let reply = try #require(sink.reply)
        #expect(host.expectReply() == nil, "a call that sent nothing has no token")

        RemoteSpy.lastToken = 41
        let early = try #require(host.expectReply())
        CEFReplyWaitersTests.int32(7).withUnsafeBytes { reply(sink.context, early, $0.baseAddress, $0.count) }
        #expect(try await host.replies.reply(to: early, as: Int32.self, label: "content setting", timeout: .seconds(30)) == 7)

        RemoteSpy.lastToken = 42
        let late = try #require(host.expectReply())
        let wait = CEFReplyWaitersTests.waiting(host.replies, late)
        await CEFReplyWaitersTests.afterQueuedWork()
        #expect(host.replies.awaiting == 1)
        CEFReplyWaitersTests.int32(9).withUnsafeBytes { reply(sink.context, late, $0.baseAddress, $0.count) }
        #expect(try await wait.value == 9)
        #expect(host.replies.count == 0)
    }

    /// The runtime's reply route is the attach's one table: a REPLY through the remote shim's reply
    /// callback answers both an async caller (`answer`) and a synchronous one (`whenAnswered`).
    @Test func theRuntimesRouteAnswersFromTheShimsReplyCallback() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        let host = try #require(runtime.hostStart)
        let sink = try #require(RemoteSpy.replySink)
        let reply = try #require(sink.reply)

        RemoteSpy.nextToken = 51
        var seen: [CEFContentSetting?] = []
        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        #expect(seen.isEmpty)
        CEFReplyWaitersTests.int32(CEFContentSetting.block.rawValue).withUnsafeBytes { reply(sink.context, 51, $0.baseAddress, $0.count) }
        #expect(seen == [.block])

        RemoteSpy.nextToken = 52
        let asked = Task { await runtime.contentSetting(1, url: nil, kind: .camera) }
        for _ in 0..<1_000 where host.replies.count == 0 { await Task.yield() }
        CEFReplyWaitersTests.int32(CEFContentSetting.allow.rawValue).withUnsafeBytes { reply(sink.context, 52, $0.baseAddress, $0.count) }
        #expect(await asked.value == .allow)
        #expect(host.replies.count == 0)
    }

    /// A host that takes the wire and hangs before its hello fails the start at the deadline, and
    /// the shim gives the wire back; a hello after that changes nothing.
    @Test func aHostThatNeverSaysHelloFailsAtTheDeadlineAndDetaches() async throws {
        RemoteSpy.reset()
        RemoteSpy.helloOnAttach = false
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd), helloDeadline: .seconds(30), clock: ImmediateClock())

        await Self.expectFailed(runtime)

        #expect(RemoteSpy.attachedFDs == [wire.fd])
        #expect(RemoteSpy.detachCalls == 1)
        #expect(!RemoteSpy.hasPendingHello, "detach left the hello pending")
        #expect(RemoteSpy.initializeFrameworkPaths.isEmpty)
        #expect(runtime.shim == nil)
    }

    /// A dylib without the full shim ABI fails before it takes the host's wire.
    @Test func aRemoteShimMissingARequiredExportNeverAttaches() async throws {
        RemoteSpy.reset()
        let lacking: @Sendable (String) -> UnsafeMutableRawPointer? = { $0 == "cmux_shim_initialize" ? nil : RemoteSpy.symbol($0) }
        #expect(throws: CEFShimLibrary.LoadError.missingSymbol("cmux_shim_initialize")) {
            try CEFRemoteShim.make(symbol: lacking, expected: RemoteSpy.abi)
        }

        let wire = try Wire()
        defer { wire.close() }
        // The runtime closes the descriptors the shim never took: hand it its own.
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: dup(wire.fd)), symbol: lacking)
        await Self.expectFailed(runtime)

        #expect(RemoteSpy.attachedFDs.isEmpty)
        #expect(RemoteSpy.detachCalls == 0)
    }

    /// A required export that cannot be resolved after the hello detaches the shim.
    @Test func aShimThatFailsToResolveAfterTheHelloDetaches() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let vanishing: @Sendable (String) -> UnsafeMutableRawPointer? = {
            $0 == "cmux_shim_initialize" && !RemoteSpy.attachedFDs.isEmpty ? nil : RemoteSpy.symbol($0)
        }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd), symbol: vanishing)

        await Self.expectFailed(runtime)

        #expect(RemoteSpy.attachedFDs == [wire.fd])
        #expect(RemoteSpy.detachCalls == 1)
    }

    /// `cmux_shim_initialize` failing on the host's wire detaches the shim.
    @Test func aFailedInitializeDetaches() async throws {
        RemoteSpy.reset()
        RemoteSpy.initializeResult = 0
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))

        await Self.expectFailed(runtime)

        #expect(RemoteSpy.initializeFrameworkPaths == [""])
        #expect(RemoteSpy.detachCalls == 1)
    }

    @Test func concurrentStartsAttachOnce() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let supervisor = FakeSupervisor(controlFD: wire.fd)
        let runtime = Self.runtime(supervisor: supervisor)

        let first = Task { try await runtime.start(layout: nil, environment: [:], trigger: "tab") }
        let second = Task { try await runtime.start(layout: nil, environment: [:], trigger: "warm") }
        try await first.value
        try await second.value

        #expect(supervisor.asked == 1)
        #expect(RemoteSpy.attachedFDs.count == 1)
        #expect(RemoteSpy.initializeFrameworkPaths.count == 1)
        #expect(RemoteSpy.inProcessLoads == 0)
    }

    /// A host that cannot start fails the start; Chromium never falls back into this process.
    @Test func aHostThatCannotStartFailsWithoutLoadingInProcess() async {
        RemoteSpy.reset()
        let supervisor = FakeSupervisor(controlFD: -1)
        supervisor.failure = .cannotStart("no host executable")
        let runtime = Self.runtime(supervisor: supervisor)

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }

        guard case .failed = runtime.state else {
            Issue.record("state \(runtime.state), expected failed")
            return
        }
        #expect(RemoteSpy.inProcessLoads == 0)
        #expect(RemoteSpy.attachedFDs.isEmpty)
        #expect(runtime.shim == nil)
    }

    /// A start marks `cef.initialize_started` and `cef.initialize_ended` around its
    /// initialize, once: host mode loads no library (no preload or load marks), and a second start
    /// marks nothing. The first page paint then names the start's trigger.
    @Test func aStartMarksItsInitializeOnce() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive

        try await runtime.start(layout: nil, environment: [:], trigger: "restoredTab")
        try await runtime.start(layout: nil, environment: [:], trigger: "tab")
        runtime.firstPagePainted(shown: true)

        #expect(log.names == ["cef.initialize_started", "cef.initialize_ended",
                              "cef.first_page_paint", "cef.first_page_paint.trigger.restoredTab"])
    }

    /// The ready hooks start Chromium's Energy Saver with the runtime's policy, and what
    /// `debug.energy` reads (`CEFEngine.energySaverApplied`, ``CEFEnergySaver/applied(by:)``) is the fork's
    /// answer: applied when it took the state, not when it refused, and nothing before the start.
    @Test func theReadyHooksStartTheEnergySaverAndReportTheForksAnswer() async throws {
        for (answer, applied) in [(Int32(1), true), (Int32(0), false)] {
            RemoteSpy.reset()
            RemoteSpy.forkAPI = CEFForkFeatures.energySaverForkAPI
            RemoteSpy.energySaverResult = answer
            let wire = try Wire()
            defer { wire.close() }
            let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))
            #expect(!CEFEnergySaver.applied(by: runtime))

            try await runtime.start(layout: nil, environment: [:], trigger: "test")

            #expect(RemoteSpy.energySaverCalls == [0], "the start did not send the runtime's policy (saver off)")
            #expect(CEFEnergySaver.applied(by: runtime) == applied)
        }
    }

    /// Below the fork's Energy Saver API the ready hooks make no saver and no call, and report nothing applied.
    @Test func belowTheForkAPITheReadyHooksMakeNoEnergySaver() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let runtime = Self.runtime(supervisor: FakeSupervisor(controlFD: wire.fd))

        try await runtime.start(layout: nil, environment: [:], trigger: "test")

        #expect(runtime.energySaver == nil)
        #expect(RemoteSpy.energySaverCalls.isEmpty)
        #expect(!CEFEnergySaver.applied(by: runtime))
    }

    /// The control case: without a supervisor the start is the in-process load.
    @Test func inProcessModeRunsTheInProcessLoad() async {
        RemoteSpy.reset()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        runtime.loadInProcess = { _ in
            RemoteSpy.inProcessLoads += 1
            return .failure(.notEmbedded)
        }

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }

        #expect(RemoteSpy.inProcessLoads == 1)
        #expect(runtime.hostStart == nil)
    }

    @Test func theRemoteShimChecksTheSameABIIdentity() throws {
        RemoteSpy.reset()
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "another header", found: RemoteSpy.abi)) {
            try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: "another header")
        }
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "missing", found: RemoteSpy.abi)) {
            try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: nil)
        }
        _ = try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: RemoteSpy.abi)
    }

    @Test func aRemoteShimWithoutTheWireEntryPointsDoesNotLoad() {
        #expect(throws: CEFShimLibrary.LoadError.missingSymbol("cmux_remote_shim_attach")) {
            try CEFRemoteShim.make(symbol: { $0 == "cmux_remote_shim_attach" ? nil : RemoteSpy.symbol($0) }, expected: RemoteSpy.abi)
        }
    }

    /// The remote dylib exports every optional call; only the host shim's (its hello) count.
    @Test func optionalExportsComeFromTheHostsHello() throws {
        let none = try CEFShimLibrary.resolving(RemoteSpy.symbol, hostExports: [])
        #expect(!none.hasRendererPaths)
        #expect(none.pageSchemeSetGroup == nil)
        #expect(!CEFForkFeatures(forkAPIVersion: RemoteSpy.forkAPI, shimHasRendererPaths: none.hasRendererPaths).rendererPaths)

        let all = try CEFShimLibrary.resolving(RemoteSpy.symbol, hostExports: RemoteSpy.rendererPathExports)
        #expect(all.hasRendererPaths)
        #expect(all.pageSchemeSetGroup == nil)
    }

    @Test func theSourcesSupervisorPicksTheBackend() {
        #expect(CEFRuntimeSource(layout: nil).backend == .inProcess)
        #expect(CEFRuntimeSource(layout: nil, hostSupervisor: FakeSupervisor(controlFD: -1)).backend == .host)
    }

    /// Chromium starts once per process: a runtime that already started keeps its backend.
    @Test func aStartedRuntimeIgnoresALaterSupervisor() throws {
        let runtime = CEFRuntime.spy(shim: try CEFShimLibrary.resolving(RemoteSpy.symbol), storage: CEFProfileStorage(root: Self.scratch()))
        runtime.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: FakeSupervisor(controlFD: -1))
        #expect(runtime.hostStart == nil)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-backend-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A runtime in host mode whose in-process load only counts its calls.
    private static func runtime(
        supervisor: FakeSupervisor,
        symbol: @escaping @Sendable (String) -> UnsafeMutableRawPointer? = RemoteSpy.symbol,
        helloDeadline: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock(),
        makePumpTimer: CEFInProcessPump.MakeTimer? = nil
    ) -> CEFRuntime {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: scratch()), makePumpTimer: makePumpTimer)
        runtime.loadInProcess = { _ in
            RemoteSpy.inProcessLoads += 1
            return .failure(.notEmbedded)
        }
        runtime.hostStart = CEFHostStart(supervisor: supervisor, open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: symbol, expected: RemoteSpy.abi)) } catch { return .failure(.shim(error)) }
        }, helloDeadline: helloDeadline, clock: clock)
        return runtime
    }

    private static func expectFailed(_ runtime: CEFRuntime) async {
        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }
        guard case .failed = runtime.state else {
            Issue.record("state \(runtime.state), expected failed")
            return
        }
    }
}

/// Counts the pump timers a runtime makes; each is a timer that never fires.
@MainActor
private final class PumpTimerCounter {
    private(set) var made = 0

    func make() -> any CEFPumpTimer {
        made += 1
        return SilentTimer()
    }

    private final class SilentTimer: CEFPumpTimer {
        var onFire: (() -> Void)?
        func arm(after _: TimeInterval, tolerance _: TimeInterval) {}
        func disarm() {}
        func invalidate() {}
    }
}

/// A pipe whose read end stands in for the host's control socket.
private struct Wire {
    let fd: Int32
    private let other: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        fd = fds[0]
        other = fds[1]
    }

    func close() {
        Darwin.close(fd)
        Darwin.close(other)
    }
}

/// The supervisor's side: hands out one attachment per request, or fails.
@MainActor
private final class FakeSupervisor: ChromiumHostSupervising {
    let controlFD: Int32
    var failure: ChromiumHostAttachError?
    private(set) var asked = 0

    init(controlFD: Int32) {
        self.controlFD = controlFD
    }

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        if let failure { throw failure }
        return ChromiumHostAttachment(controlFD: controlFD, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: ["en.lproj", "ja.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// The remote dylib's functions: the ABI id, attach (records the control descriptor and says hello
/// at once with no optional exports, or keeps it pending), detach (runs a pending hello with 0, as
/// the wire contract says), the fork API version, and recorders for prepare_application, initialize
/// the in-process load, set_schedule_delayed, do_work and set_energy_saver; every other function does nothing
/// and returns 0.
private nonisolated enum RemoteSpy {
    static let abi = "remote-spy-abi"
    nonisolated(unsafe) static var forkAPI: Int32 = 30
    static let rendererPathExports: Set<String> = [
        "cmux_shim_add_document_script", "cmux_shim_add_page_channel", "cmux_shim_tab_evaluate",
        "cmux_shim_tab_set_frozen", "cmux_shim_tab_send_click", "cmux_shim_tab_set_color_scheme",
    ]
    nonisolated(unsafe) static var inProcessLoads = 0
    nonisolated(unsafe) static var attachedFDs: [Int32] = []
    nonisolated(unsafe) static var prepareApplicationCalls = 0
    nonisolated(unsafe) static var initializeFrameworkPaths: [String] = []
    /// Whether each initialize got a schedule callback.
    nonisolated(unsafe) static var initializeScheduleCallbacks: [Bool] = []
    nonisolated(unsafe) static var scheduleDelayedCalls = 0
    nonisolated(unsafe) static var doWorkCalls = 0
    /// False: attach keeps the hello pending (a host that hangs before it says hello).
    nonisolated(unsafe) static var helloOnAttach = true
    nonisolated(unsafe) static var initializeResult: Int32 = 1
    nonisolated(unsafe) static var detachCalls = 0
    /// Each `cmux_shim_set_energy_saver` call's `enabled`, and what it returns.
    nonisolated(unsafe) static var energySaverCalls: [Int32] = []
    nonisolated(unsafe) static var energySaverResult: Int32 = 1
    nonisolated(unsafe) private static var pendingHello: (context: UnsafeMutableRawPointer?, hello: CEFRemoteShim.HelloFn)?
    /// What `cmux_remote_shim_set_reply` was last given (the attach's reply table, or nil after detach).
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    /// What `cmux_remote_shim_last_reply_token` returns.
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    /// The token `cmux_shim_content_setting` sends its op under, as the remote shim's PostForReply does.
    nonisolated(unsafe) static var nextToken: UInt32 = 0
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static var hasPendingHello: Bool { pendingHello != nil }

    static func reset() {
        inProcessLoads = 0
        attachedFDs = []
        prepareApplicationCalls = 0
        initializeFrameworkPaths = []
        initializeScheduleCallbacks = []
        scheduleDelayedCalls = 0
        doWorkCalls = 0
        helloOnAttach = true
        initializeResult = 1
        detachCalls = 0
        forkAPI = 30
        energySaverCalls = []
        energySaverResult = 1
        pendingHello = nil
        replySink = nil
        lastToken = 0
        nextToken = 0
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(RemoteSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { control, _, _, context, hello in
            RemoteSpy.attachedFDs.append(control)
            if RemoteSpy.helloOnAttach {
                hello?(context, 1, nil)
            } else if let hello {
                RemoteSpy.pendingHello = (context, hello)
            }
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {
            RemoteSpy.detachCalls += 1
            guard let pending = RemoteSpy.pendingHello else { return }
            RemoteSpy.pendingHello = nil
            pending.hello(pending.context, 0, nil)
        }
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in RemoteSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { RemoteSpy.lastToken }
        let forkAPIVersion: @convention(c) () -> Int32 = { RemoteSpy.forkAPI }
        let prepareApplication: @convention(c) () -> Int32 = {
            RemoteSpy.prepareApplicationCalls += 1
            return 1
        }
        let initialize: @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<UnsafePointer<CChar>?>?,
            UnsafeMutableRawPointer?, CEFShimLibrary.ScheduleFn?, CEFShimLibrary.EventFn?, CEFShimLibrary.KeyFn?
        ) -> Int32 = { framework, _, _, _, _, _, _, _, _, _, schedule, _, _ in
            RemoteSpy.initializeFrameworkPaths.append(framework.map { String(cString: $0) } ?? "nil")
            RemoteSpy.initializeScheduleCallbacks.append(schedule != nil)
            return RemoteSpy.initializeResult
        }
        let setScheduleDelayed: @convention(c) (CEFShimLibrary.ScheduleDelayedFn?) -> Int32 = { _ in
            RemoteSpy.scheduleDelayedCalls += 1
            return 0
        }
        let doWork: @convention(c) () -> Void = { RemoteSpy.doWorkCalls += 1 }
        let setEnergySaver: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { enabled, _ in
            RemoteSpy.energySaverCalls.append(enabled)
            return RemoteSpy.energySaverResult
        }
        let contentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _ in
            RemoteSpy.lastToken = RemoteSpy.nextToken
            return 0
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_content_setting": unsafeBitCast(contentSetting, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_prepare_application": unsafeBitCast(prepareApplication, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_initialize": unsafeBitCast(initialize, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_schedule_delayed": unsafeBitCast(setScheduleDelayed, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_do_work": unsafeBitCast(doWork, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_energy_saver": unsafeBitCast(setEnergySaver, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}

/// A clock whose sleeps end at once, so the hello deadline fires on the next task turn.
nonisolated private struct ImmediateClock: Clock {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
