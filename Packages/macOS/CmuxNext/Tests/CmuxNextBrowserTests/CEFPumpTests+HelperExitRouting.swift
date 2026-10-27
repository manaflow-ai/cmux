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

    /// RENDER_TERMINATED of `browser` with `cef_termination_status_t` `status`.
    private static func ended(_ browser: Int32, status: Int, end: CEFRendererEnd) -> CEFShimEvent {
        .renderTerminated(browser: browser, status: status, code: status == 2 ? Int(SIGSEGV) : 0, text: "", end: end)
    }

    private static func renderer(status: Int32) -> CEFChildProcessMonitor.Exit {
        CEFChildProcessMonitor.Exit(pid: 4300, processType: "renderer", subType: nil, isExtension: false, status: status)
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

    @Test func quitsEndsCountNothing() throws {
        let (runtime, store) = try Self.exitRig()
        _ = Self.exitTab(runtime, browser: 1)
        runtime.shutdownSequence = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        runtime.handle(Self.ended(1, status: 1, end: .first))
        runtime.childExited(Self.renderer(status: SIGKILL))
        runtime.childExited(CEFChildProcessMonitor.Exit(pid: 4401, processType: "gpu-process", subType: nil, isExtension: false, status: SIGKILL))
        runtime.shutdownSequence = nil
        runtime.state = .shutDown
        runtime.handle(Self.ended(1, status: 2, end: .first))
        #expect(Self.helperExitCounts(in: store).isEmpty)
    }
}

/// A shim whose every export does nothing and returns 0.
private nonisolated enum QuietShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
