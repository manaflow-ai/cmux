import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextTrace
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// When the Chromium Host ends, every page it showed shows the crash state of its
/// end, every reply still awaited fails, the crash log records the host once, and the runtime leaves
/// ready: nothing goes to the dead wire, and the next start (a new tab, or a sad tab's Reload) asks the
/// supervisor for a host again. Against a spy remote shim and a supervisor that reports host ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostExitTests {
    private static let killed = BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef)
    private static let page = URL(string: "https://example.com/")!
    private static let elsewhere = URL(string: "https://example.org/next")!

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

    /// Each attach tells the supervisor its host's fork API, which that host's crash record names.
    @Test func theAttachTellsTheSupervisorItsHostsForkAPI() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: 2)
        defer { wire.close() }
        #expect(supervisor.forkAPIs == [2])
        supervisor.onHostEnded?(Self.killed)
        HostWire.state.withLock { $0.forkAPI = 3 }
        try await runtime.start(layout: nil, environment: [:], trigger: "tab")
        #expect(supervisor.forkAPIs == [2, 3])
    }

    /// In host mode Chromium's log is the one the host's spawn names (`--log-file`, whose end the
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

    /// The order of the supervisor's two reports of one end: its end observers (``ChromiumHostSupervising/observeHostEnds(_:)``)
    /// and its exit report (``ChromiumHostExitReporting/onHostEnded``).
    nonisolated enum ReportOrder: CaseIterable, Sendable {
        case observersFirst, exitReportFirst
    }

    /// Task 091: whichever report of the host's end comes first detaches the dead wire before anything resolves. A person's
    /// close waiting on its try_close answer, with the page's beforeunload open, closes its tab (out of its pane), the
    /// question's answer goes nowhere, and the crash log records the host once.
    @Test(arguments: ReportOrder.allCases)
    func aPersonsCloseTheEndAnswersClosesItsTabAndNothingReachesTheDeadWire(_ order: ReportOrder) async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        let pane = tab.host
        let closer = TabCloser()
        tab.delegate = closer
        // The tab holds its delegate weakly; the test's closer outlives it.
        _ = Unmanaged.passRetained(closer)
        #expect(tab.beginUserClose(), "the close did not wait for the page's answer")
        tab.beforeUnloadAsked(token: 5, isReload: false)
        #expect(tab.asksBeforeUnload)

        switch order {
        case .observersFirst:
            supervisor.endObservers()
            #expect(tab.isClosed, "the person's close waited for an answer the dead host cannot send")
            supervisor.onHostEnded?(Self.killed)
        case .exitReportFirst:
            supervisor.onHostEnded?(Self.killed)
            supervisor.endObservers()
        }

        #expect(tab.isClosed && closer.closes == 1)
        #expect(!pane.tabs.contains { $0 === tab }, "the closed tab stayed in its pane, waiting for a BEFORE_CLOSE")
        #expect(HostWire.state.withLock { $0.deadWireOps } == 0, "an answer or the close went to the dead host's wire")
        #expect(HostWire.state.withLock { $0.detaches } == 1)
        #expect(runtime.crashLog.records.map(\.processType) == ["chromium-host"])
        #expect(runtime.state == .idle && runtime.shim == nil)
    }

    /// A host whose end only the observers report (a clean exit) still leaves no wire to send to and no wait.
    @Test func anEndOnlyTheObserversReportDetachesTheWire() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        _ = Self.tab(runtime, browser: 1)
        let sent = runtime.sendAsync { $0.tryClose(1) }
        guard case .later = sent else {
            Issue.record("the op was not sent for a REPLY")
            return
        }
        var settled: [Result<Int32, CEFHostReplyError>] = []
        runtime.whenSettled(sent, label: "try close") { settled.append($0) }

        supervisor.endObservers()

        #expect(settled == [.failure(.hostGone)], "a reply awaited from the dead host waits for its deadline")
        #expect(runtime.state == .idle && runtime.shim == nil)
        #expect(runtime.awaitsHostRestart)
        #expect(HostWire.state.withLock { $0.detaches } == 1)
        #expect(runtime.crashLog.records.isEmpty, "a clean end was logged as a crash")
    }

    /// An Energy Saver edge while no host runs reaches nobody, so the next host's ready sends the
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

    /// In host mode as in process, one renderer's end is one `cef.helper_exit` sample however
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

    /// A crash within the restart budget starts the next host at once and brings back every page of
    /// every window and profile with the navigation its daemon record saved at its address: a shown page asks the new
    /// host for its browser now, a hidden one keeps its crash page until it shows, and each restores its saved
    /// navigation on its new browser (a page with no record loads its address).
    @Test func aCrashWithinTheBudgetBringsBackEveryPageWithItsSavedNavigation() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.navigationRestoreForkAPI)
        defer { wire.close() }
        let pages = (1...3).map { URL(string: "https://example.com/\($0)")! }
        let work = BrowserProfileID(rawValue: UUID())
        let tabs = [Self.tab(runtime, browser: 1), Self.tab(runtime, browser: 2, profile: work), Self.tab(runtime, browser: 3)]
        for (tab, url) in zip(tabs, pages) { tab.committedURL = url }
        // The first page is shown in its pane; the others are hidden.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        tabs[0].host.present(tabs[0], in: container)
        let saved = [tabs[0].id: "state-1", tabs[1].id: "state-2"]  // the third tab has no record
        let asked = AskedURLs()
        supervisor.savedNavigation = { id, url in
            asked.urls.append(url)
            return saved[id].map(BrowserRestoreState.chromium)
        }
        supervisor.lastEndRestoresPages = true

        supervisor.onHostEnded?(Self.killed)
        #expect(tabs.allSatisfy { $0.state.processExit == Self.killed }, "a page left its crash page before the next host")
        let restores = try #require(runtime.hostStart?.pageRestores)
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        // Joins the restore's attach, so the test resumes once the runtime is ready again.
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where tabs.dropFirst().contains(where: { restores.phase(of: $0) != .waitsForShow }) { await Task.yield() }

        #expect(supervisor.asked == 2, "no host started after a crash within the budget")
        #expect(Set(asked.urls) == Set(pages), "a page's saved navigation was not read at its address")
        #expect(tabs.map(\.pendingRestore) == ["state-1", "state-2", nil])
        #expect(tabs.map(\.pendingURL) == pages)
        #expect(tabs[0].state.processExit == nil && tabs[0].isCreationPending, "the shown page did not ask the new host for its browser")
        #expect(restores.phase(of: tabs[0]) == nil)
        #expect(tabs.dropFirst().allSatisfy { $0.state.processExit == Self.killed }, "a hidden page started before it showed")
        #expect(HostWire.state.withLock { $0.deadWireOps } == 0, "an op went to the dead host's wire")

        // Shown, a hidden page starts; each new browser restores its saved navigation.
        tabs[1].contentDidAppear(in: tabs[1].container)
        #expect(tabs[1].state.processExit == nil && restores.phase(of: tabs[1]) == nil)
        for (index, tab) in tabs.enumerated() { runtime.register(tab, browser: Int32(11 + index)) }
        #expect(HostWire.state.withLock { $0.restoredBrowsers } == [11, 12], "a page came back without its saved navigation")
        #expect(HostWire.state.withLock { $0.restoredStates } == ["state-1", "state-2"])
    }

    /// A page sent to a new address while its restore reads its saved navigation (a person's address,
    /// a script, the CLI or MCP) loads that address on the next host: its restore ends, and its new browser is made
    /// with the new address and restores nothing.
    @Test func aLoadWhileTheRestoreReadsLoadsTheNewAddressOnTheNextHost() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.navigationRestoreForkAPI)
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        tab.committedURL = Self.page
        tab.host.present(tab, in: NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        supervisor.savedNavigation = { _, _ in .chromium("state-1") }
        supervisor.lastEndRestoresPages = true
        let restores = try #require(runtime.hostStart?.pageRestores)

        supervisor.onHostEnded?(Self.killed)
        #expect(restores.blocksCreation(of: tab), "the page did not wait for its restore")
        tab.load(Self.elsewhere)
        #expect(restores.phase(of: tab) == nil, "the navigation left the restore waiting")
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        // Joins the restore's attach, so the test resumes once the runtime is ready again.
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where !tab.isCreationPending { await Task.yield() }

        #expect(supervisor.asked == 2)
        #expect(tab.isCreationPending, "the shown page did not ask the new host for its browser")
        #expect(tab.pendingRestore == nil && tab.pendingURL == Self.elsewhere, "the restore put the old page back")
        #expect(HostWire.state.withLock { $0.createdURLs } == [Self.elsewhere.absoluteString])
        runtime.register(tab, browser: 11)
        #expect(HostWire.state.withLock { $0.restoredBrowsers }.isEmpty, "the new browser restored the old navigation")
        #expect(tab.state.url == Self.elsewhere)
    }

    /// A hidden page whose restore waits for it to show, sent to a new address meanwhile, shows that
    /// address: its browser is made with it and restores nothing. A Reload before then keeps the restore.
    @Test func aLoadOfAHiddenPageWaitingForItsRestoreLoadsTheNewAddressWhenItShows() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.navigationRestoreForkAPI)
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        tab.committedURL = Self.page
        supervisor.savedNavigation = { _, _ in .chromium("state-1") }
        supervisor.lastEndRestoresPages = true
        let restores = try #require(runtime.hostStart?.pageRestores)
        supervisor.onHostEnded?(Self.killed)
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where restores.phase(of: tab) != .waitsForShow { await Task.yield() }
        try #require(restores.phase(of: tab) == .waitsForShow)

        tab.reload()
        #expect(restores.phase(of: tab) == .waitsForShow && tab.pendingRestore == "state-1", "a Reload dropped the restore")
        tab.load(Self.elsewhere)
        #expect(restores.phase(of: tab) == nil && tab.pendingRestore == nil, "the navigation left the restore waiting")

        tab.contentDidAppear(in: tab.container)
        #expect(tab.isCreationPending, "the shown page did not ask for its browser")
        #expect(HostWire.state.withLock { $0.createdURLs } == [Self.elsewhere.absoluteString])
        runtime.register(tab, browser: 11)
        #expect(HostWire.state.withLock { $0.restoredBrowsers }.isEmpty, "the new browser restored the old navigation")
        #expect(tab.state.url == Self.elsewhere, "the address and the page do not match")
    }

    /// A page that showed a form's result (a POST) is never sent again without the person: it keeps
    /// its crash page, shown or hidden, and no host starts for it.
    @Test func aFormResultKeepsItsCrashPageAfterACrashWithinTheBudget() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.navigationRestoreForkAPI)
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        tab.committedURL = Self.page
        tab.restored.documentCommitted(url: Self.page, formPost: true)
        supervisor.lastEndRestoresPages = true

        supervisor.onHostEnded?(Self.killed)
        for _ in 0..<100 { await Task.yield() }

        #expect(supervisor.asked == 1, "a host started to send a form again")
        #expect(tab.state.processExit == Self.killed)
        #expect(!tab.reloadWhenShown, "the form's page would load again when it shows")
        #expect(runtime.hostStart?.pageRestores.phase(of: tab) == nil)
    }

    /// Past the restart budget nothing comes back on its own: each page keeps its crash page and
    /// reloads when it shows, as before.
    @Test func aCrashPastTheBudgetRestoresNothing() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.navigationRestoreForkAPI)
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        tab.committedURL = Self.page

        supervisor.onHostEnded?(Self.killed)
        for _ in 0..<100 { await Task.yield() }

        #expect(supervisor.asked == 1)
        #expect(tab.state.processExit == Self.killed)
        #expect(tab.reloadWhenShown)
        #expect(runtime.hostStart?.pageRestores.phase(of: tab) == nil)
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

    // MARK: Crash page

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

    /// A tab of `profile` in a pane of its own whose browser is `browser`.
    private static func tab(_ runtime: CEFRuntime, browser: Int32, profile: BrowserProfileID = .default) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: profile), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: profile, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: browser)
        return tab
    }
}

/// Hands out the spy's wire on each request and reports host ends through ``onHostEnded``, which the
/// runtime sets.
@MainActor private final class ReportingHost: @MainActor ChromiumHostExitReporting {
    var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?
    /// Whether the next reported end is within the restart budget.
    var lastEndRestoresPages = false
    var savedNavigation: ChromiumHostSavedNavigation?
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

    private var observers: [@MainActor () -> Void] = []

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        observers.append(ended)
    }

    /// Runs every end observer, as the supervisor does for any end of its host.
    func endObservers() {
        for observer in observers { observer() }
    }

    func hostSaidHello() {}

    /// The fork API each attach read from its host.
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

/// The addresses whose saved navigation the runtime asked for.
@MainActor private final class AskedURLs {
    var urls: [URL] = []
}

/// Closes the tab when it asks to close, as the app's tab owner does.
@MainActor private final class TabCloser: BrowserTabDelegate {
    private(set) var closes = 0

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        guard case .close = intent else { return }
        closes += 1
        (tab as? CEFTab)?.close()
    }
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
/// `close`, `create_window`, `try_close` (sent for a REPLY: the next token) and `before_unload_reply`, which
/// count the ops sent while no wire is attached. Every other export does nothing and returns 0.
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
        /// Each `cmux_shim_tab_restore_navigation` call's browser and state.
        var restoredBrowsers: [Int32] = []
        var restoredStates: [String] = []
        /// Each `cmux_shim_create_window` call's URL while a wire is attached.
        var createdURLs: [String] = []
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
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, url, _ in
            HostWire.op()
            let text = url.map { unsafe String(cString: $0) } ?? ""
            return HostWire.state.withLock { wire in
                guard wire.live else { return 0 }
                wire.createdURLs.append(text)
                return 1
            }
        }
        let restoreSupported: @convention(c) () -> Int32 = { 1 }
        let restoreNavigation: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, state in
            let text = state.map { unsafe String(cString: $0) } ?? ""
            HostWire.state.withLock { wire in
                wire.restoredBrowsers.append(browser)
                wire.restoredStates.append(text)
            }
            return 1
        }
        let tryClose: @convention(c) (Int32) -> Int32 = { _ in
            HostWire.op()
            HostWire.state.withLock { $0.token += 1 }
            return 1
        }
        let beforeUnloadReply: @convention(c) (Int32, Int32) -> Int32 = { _, _ in
            HostWire.op()
            return 1
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
        case "cmux_shim_navigation_restore_supported": unsafeBitCast(restoreSupported, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_restore_navigation": unsafeBitCast(restoreNavigation, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_try_close": unsafeBitCast(tryClose, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_before_unload_reply": unsafeBitCast(beforeUnloadReply, to: UnsafeMutableRawPointer.self)
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
