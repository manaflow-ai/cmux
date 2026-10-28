@testable import CmuxNextBrowser
import CmuxNextMetrics
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// Where `cef.helper_exit` samples come from (p09-observability task 060), against a ready runtime over a quiet spy
/// shim: a page renderer counts once per process from Chromium's termination status (RENDER_TERMINATED, whose
/// `request` names the first browser of the end), whether or not the child monitor runs or a tab shows it; the
/// monitor counts only the helpers no tab hears about; quit's ends count nothing. Each test records into its own store.
extension CEFPumpTests {
    /// A ready in-process runtime whose samples go to the returned store. It outlives the test: a pane's scheduled
    /// work reads it through an unowned reference.
    private static func exitRig() throws -> (CEFRuntime, MetricsStore) {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-helper-exit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(QuietShim.symbol), storage: CEFProfileStorage(root: root))
        runtime.helperExits = CEFHelperExitMetric(metrics: Metrics(runtime: trace))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, store)
    }

    /// A tab in a pane of its own whose browser is `browser`.
    private static func exitTab(_ runtime: CEFRuntime, browser: Int32) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: browser)
        return tab
    }

    /// RENDER_TERMINATED of `browser` with `cef_termination_status_t` `status`, naming renderer `client` (0: none).
    private static func ended(_ browser: Int32, status: Int, end: CEFRendererEnd, client: Int32 = 0) -> CEFShimEvent {
        .renderTerminated(browser: browser, status: status, code: status == 2 ? Int(SIGSEGV) : 0, text: "", end: end, client: client)
    }

    /// The monitor's exit of page renderer `pid` with `--renderer-client-id` `client`.
    private static func renderer(status: Int32, pid: Int32 = 4300, client: Int32? = nil) -> CEFChildProcessMonitor.Exit {
        CEFChildProcessMonitor.Exit(pid: pid, processType: "renderer", subType: nil, isExtension: false, status: status,
                                    rendererClientID: client)
    }

    /// ``exitRig()`` with a child monitor (it watches nothing; the test reports its exits) and a deadline queue
    /// only the returned rig moves, where a renderer's helper-exit report waits for its other half.
    private static func pidRig() throws -> (CEFRuntime, ReplyDeadlineRig, HelperExitSink) {
        let (runtime, _) = try exitRig()
        let deadlines = ReplyDeadlineRig()
        runtime.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), waitDeadlines: deadlines.queue)
        runtime.childMonitor = CEFChildProcessMonitor { _ in }
        return (runtime, deadlines, HelperExitSink(runtime.crashLog))
    }

    /// The `cef.helper_exit` samples by value (an enumeration's bucket index is its value).
    private static func helperExitCounts(in store: MetricsStore) -> [Int: UInt64] {
        let buckets = Self.histogram(.cefHelperExit, in: store)?.buckets ?? []
        return Dictionary(uniqueKeysWithValues: buckets.map { ($0.index, $0.count) })
    }

    @Test func aRendererSharedByTwoTabsEndsAsOneSample() throws {
        let (runtime, store) = try Self.exitRig()
        let first = Self.exitTab(runtime, browser: 1)
        let second = Self.exitTab(runtime, browser: 2)
        runtime.handle(Self.ended(1, status: 2, end: .first))
        runtime.handle(Self.ended(2, status: 2, end: .shared))
        #expect(first.state.processExit?.reason == .crashed && second.state.processExit?.reason == .crashed, "each tab shows its sad tab")
        #expect(runtime.crashLog.records.count == 2, "each tab logs its renderer's end")
        #expect(Self.helperExitCounts(in: store) == [17: 1], "one renderer crash, not one per tab")
    }

    @Test func aTabsEndAndTheMonitorsExitOfTheSameRendererAreOneSample() throws {
        let (runtime, store) = try Self.exitRig()
        _ = Self.exitTab(runtime, browser: 1)
        runtime.handle(Self.ended(1, status: 2, end: .first))
        runtime.childExited(Self.renderer(status: SIGSEGV))
        #expect(runtime.crashLog.records.map(\.source) == [.engine, .process], "both still log")
        #expect(Self.helperExitCounts(in: store) == [17: 1])
    }

    /// Chromium's status names what a wait status cannot: a launch failure (no exec'd renderer for the monitor), a
    /// kill (Exit page sends SIGTERM, which the monitor reads as a normal end), OOM and an integrity failure.
    @Test func eachRendererReasonComesFromChromiumsStatus() throws {
        let (runtime, store) = try Self.exitRig()
        for (browser, status) in zip(Int32(1)..., [1, 2, 3, 4, 5, 0]) {
            _ = Self.exitTab(runtime, browser: browser)
            runtime.handle(Self.ended(browser, status: status, end: .first))
        }
        runtime.childExited(Self.renderer(status: SIGTERM))
        runtime.childExited(Self.renderer(status: SIGKILL))
        #expect(Self.helperExitCounts(in: store) == [18: 1, 17: 1, 19: 1, 20: 1, 21: 1, 22: 1],
                "killed, crashed, OOM, launch failed, integrity, abnormal: one each")
    }

    /// A child monitor that watches nothing (its kqueue failed) hides no renderer end.
    @Test func aDeadMonitorHidesNoRendererEnd() throws {
        let (runtime, store) = try Self.exitRig()
        runtime.childMonitor = CEFChildProcessMonitor { _ in }
        _ = Self.exitTab(runtime, browser: 1)
        runtime.handle(Self.ended(1, status: 4, end: .first))
        #expect(Self.helperExitCounts(in: store) == [20: 1])
    }

    @Test func aRendererEndCountsWithNoTabToShowIt() throws {
        let (runtime, store) = try Self.exitRig()
        runtime.handle(Self.ended(9, status: 2, end: .first))
        runtime.handle(Self.ended(10, status: 2, end: .unknown))
        runtime.handle(Self.ended(11, status: 2, end: .shared))
        #expect(Self.helperExitCounts(in: store) == [17: 2], "a shim that cannot name the process counts per browser")
    }

    @Test func theMonitorCountsTheHelpersNoTabHearsAbout() throws {
        let (runtime, store) = try Self.exitRig()
        func helper(_ type: String, extension isExtension: Bool = false, _ status: Int32) -> CEFChildProcessMonitor.Exit {
            CEFChildProcessMonitor.Exit(pid: 4400, processType: type, subType: nil, isExtension: isExtension, status: status)
        }
        runtime.childExited(helper("gpu-process", SIGSEGV))
        runtime.childExited(helper("utility", SIGKILL))
        runtime.childExited(helper("renderer", extension: true, 1 << 8))
        runtime.childExited(helper("crashpad-handler", SIGABRT))
        runtime.childExited(helper("gpu-process", SIGTERM))
        #expect(Self.helperExitCounts(in: store) == [49: 1, 66: 1, 38: 1, 1: 1], "gpu crash, utility kill, extension exit 1, other crash")
    }

    /// Every `BrowserCrashLog.helperExited` of the runtime, in order.
    private final class HelperExitSink {
        var exits: [BrowserHelperExit] = []
        init(_ log: BrowserCrashLog) { log.addHelperExitObserver { [unowned self] in self.exits.append($0) } }
    }

    /// One helper-exit report per process: a renderer shared by two tabs and also seen by the
    /// monitor is one report, with Chromium's reason and the monitor's pid (the one in its `.ips` and minidump), joined
    /// by the renderer's client id, and with no tab, URL or title in it.
    @Test func aRendererSeenThreeWaysIsOneHelperExitReportWithItsPid() throws {
        let (runtime, deadlines, sink) = try Self.pidRig()
        _ = Self.exitTab(runtime, browser: 1)
        _ = Self.exitTab(runtime, browser: 2)
        runtime.handle(Self.ended(1, status: 3, end: .first, client: 7))
        runtime.handle(Self.ended(2, status: 3, end: .shared, client: 7))
        #expect(sink.exits.isEmpty, "Chromium's status waits for the monitor's pid")
        runtime.childExited(Self.renderer(status: SIGKILL, client: 7))
        #expect(sink.exits == [BrowserHelperExit(processType: "renderer", chromiumType: "renderer", pid: 4300, reason: .outOfMemory,
                                                 pump: ["mode": "none"])],
                "Chromium's OOM, not the monitor's kill; a runtime with no pump and no host names neither mode")
        #expect(runtime.helperExitReports.waitingCount == 0)
        deadlines.advance(by: CEFHelperExitReports.wait + .seconds(2))
        #expect(sink.exits.count == 1, "the join cancelled the wait")
    }

    /// The monitor's exit can come first; two renderers ending together each get their own pid, by client id.
    @Test func eachRendererReportTakesThePidOfItsOwnClientID() throws {
        let (runtime, _, sink) = try Self.pidRig()
        runtime.childExited(Self.renderer(status: SIGSEGV, pid: 4308, client: 8))
        runtime.handle(Self.ended(1, status: 2, end: .first, client: 7))
        runtime.handle(Self.ended(2, status: 1, end: .first, client: 8))
        runtime.childExited(Self.renderer(status: SIGKILL, pid: 4307, client: 7))
        #expect(sink.exits.map(\.pid) == [4308, 4307])
        #expect(sink.exits.map(\.reason) == [.killed, .crashed], "each from Chromium's status of its own renderer")
        #expect(runtime.helperExitReports.waitingCount == 0)
    }

    /// A report whose other half never comes: Chromium's status goes alone after the wait, with no pid (a launch
    /// failure has no process); the monitor's alone sends nothing (the crash log keeps it).
    @Test func aRendererReportWaitsAtMostTwoSecondsForItsPid() throws {
        let (runtime, deadlines, sink) = try Self.pidRig()
        runtime.handle(Self.ended(1, status: 4, end: .first, client: 7))
        runtime.childExited(Self.renderer(status: SIGSEGV, pid: 4309, client: 9))
        deadlines.advance(by: CEFHelperExitReports.wait - .milliseconds(1))
        #expect(sink.exits.isEmpty)
        deadlines.advance(by: .seconds(2))
        #expect(sink.exits.map(\.reason) == [.launchFailed] && sink.exits.map(\.pid) == [nil])
        #expect(runtime.helperExitReports.waitingCount == 0)
        #expect(runtime.crashLog.records.map(\.pid) == [4309])
    }

    /// With nothing to join (no monitor, as in host mode, or a shim that names no renderer) the report goes at once.
    @Test func aRendererEndWithNothingToJoinGoesAtOnce() throws {
        let (runtime, _, sink) = try Self.pidRig()
        runtime.handle(Self.ended(1, status: 2, end: .first))
        let (lone, _) = try Self.exitRig()
        let loneSink = HelperExitSink(lone.crashLog)
        lone.handle(Self.ended(1, status: 2, end: .first, client: 7))
        #expect(sink.exits.map(\.pid) == [nil] && loneSink.exits.map(\.pid) == [nil])
        #expect(runtime.helperExitReports.waitingCount == 0 && lone.helperExitReports.waitingCount == 0)
    }

    /// RENDER_TERMINATED's b carries Chromium's error code and the renderer's client id (the shim's RendererEndCode).
    @Test func renderTerminatedDecodesTheClientIDAboveTheCode() {
        #expect(CEFShimEvent(kind: 23, browser: 5, request: 1, a: 2, b: (12 << 32) | 11, s1: "x", s2: "")
            == .renderTerminated(browser: 5, status: 2, code: 11, text: "x", end: .first, client: 12))
        #expect(CEFShimEvent(kind: 23, browser: 5, request: 2, a: 1, b: (12 << 32) | 0xFFFF_FFFF, s1: "", s2: "")
            == .renderTerminated(browser: 5, status: 1, code: -1, text: "", end: .shared, client: 12))
        #expect(CEFShimEvent(kind: 23, browser: 5, request: 0, a: 2, b: 11, s1: "", s2: "")
            == .renderTerminated(browser: 5, status: 2, code: 11, text: "", end: .unknown, client: 0))
        let identity = CEFHelperIdentity.parse(["h", "--type=renderer", "--renderer-client-id=12"])
        #expect(identity?.rendererClientID == 12)
    }

    /// The monitor's helpers keep their pid, the one in their `.ips` and minidump, and their sub type.
    @Test func theMonitorsHelperExitReportsKeepThePid() throws {
        let (runtime, _) = try Self.exitRig()
        let sink = HelperExitSink(runtime.crashLog)
        runtime.childExited(CEFChildProcessMonitor.Exit(pid: 4400, processType: "utility", subType: "network.mojom.NetworkService",
                                                        isExtension: false, status: SIGSEGV))
        runtime.childExited(CEFChildProcessMonitor.Exit(pid: 4401, processType: "renderer", subType: nil, isExtension: true, status: SIGABRT))
        runtime.childExited(CEFChildProcessMonitor.Exit(pid: 4402, processType: "gpu-process", subType: nil, isExtension: false, status: SIGTERM))
        #expect(sink.exits.map(\.processType) == ["utility", "extension"], "SIGTERM is a normal end")
        #expect(sink.exits.map(\.pid) == [4400, 4401])
        #expect(sink.exits.map(\.chromiumType) == ["utility", "renderer"])
        #expect(sink.exits.first?.subType == "network.mojom.NetworkService")
        #expect(sink.exits.first?.code == Int(SIGSEGV) && sink.exits.first?.codeDescription == "SIGSEGV")
    }

    @Test func quitsEndsCountNothing() throws {
        let (runtime, store) = try Self.exitRig()
        let sink = HelperExitSink(runtime.crashLog)
        _ = Self.exitTab(runtime, browser: 1)
        runtime.shutdownSequence = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        runtime.handle(Self.ended(1, status: 1, end: .first))
        runtime.childExited(Self.renderer(status: SIGKILL))
        runtime.childExited(CEFChildProcessMonitor.Exit(pid: 4401, processType: "gpu-process", subType: nil, isExtension: false, status: SIGKILL))
        runtime.shutdownSequence = nil
        runtime.state = .shutDown
        runtime.handle(Self.ended(1, status: 2, end: .first))
        #expect(Self.helperExitCounts(in: store).isEmpty)
        #expect(sink.exits.isEmpty, "quit's ends send nothing")
    }
}

/// A shim whose every export does nothing and returns 0.
private nonisolated enum QuietShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
