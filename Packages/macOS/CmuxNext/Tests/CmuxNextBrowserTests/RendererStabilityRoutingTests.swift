import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextMetrics
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// p09-observability-108 in the browser engines: a WebKit tab's content-process end, and a Chromium tab's "Page
/// unresponsive" state from its start to each way it ends (the renderer answers, the person's Wait, a renderer end, a
/// new navigation, a close), reach the engine's ``RendererStability`` once each, as counts and rate-limited reports
/// that name no page. Chromium's events go through the real runtime and tab against a spy shim.
@MainActor @Suite(.serialized) struct RendererStabilityRoutingTests {
    private static let planted = URL(string: "https://planted.example/account?token=s3cr3t")!

    // MARK: WebKit

    @Test func threeWebKitEndsAreThreeCountsAndOneReportThatNamesNoPage() throws {
        let rig = StabilityRig()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        engine.rendererStability = rig.stability
        let tab = engine.makeWebKitTab()
        defer { tab.close(); withExtendedLifetime(engine) {} } // the tab holds its engine weakly
        tab.apply(.urlChanged(Self.planted))
        try #require(tab.state.url == Self.planted)

        for _ in 0 ..< 3 { tab.webViewWebContentProcessDidTerminate(tab.webView) }

        #expect(rig.reports == [.init(kind: .contentEnded, engine: .webKit, surface: .browserTab, count: 1)])
        #expect(rig.histogram(.stabilityChildExit(.webkit))?.count == 3)
        #expect(tab.state.processExit != nil, "the sad tab still shows")
        #expect(!String(reflecting: rig.reports).contains("planted.example"), "a report names no page")
    }

    // MARK: Chromium

    @Test func aHangTheRendererEndsIsOneSampleFromShownToEnded() throws {
        let rig = try CEFStabilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        rig.runtime.handle(.renderUnresponsive(browser: 7)) // Chromium says it again: one span
        rig.recorded.advance(milliseconds: 2_000)
        rig.runtime.handle(.renderResponsive(browser: 7))

        #expect(!tab.state.isUnresponsive)
        #expect(rig.recorded.reports == [.init(kind: .unresponsive, engine: .chromium, surface: .browserTab, count: 1,
                                                milliseconds: 2_000, ending: .responsive)])
        let hang = try #require(rig.recorded.histogram(.rendererUnresponsive))
        #expect(hang.count == 1 && hang.sum == 2_000)
    }

    @Test func eachWayAHangEndsIsItsEnding() throws {
        let rig = try CEFStabilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        tab.answerUnresponsivePage(terminate: false) // Wait
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        rig.runtime.handle(.renderTerminated(browser: 7, status: 2, code: 11, text: "crashed", end: .first)) // Exit page
        rig.runtime.handle(.renderUnresponsive(browser: 7)) // a gone page is never unresponsive
        tab.load(Self.planted)
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        tab.load(URL(string: "https://example.com/next")!)
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        tab.close()

        #expect(rig.recorded.endings == [.responsive, .processEnded, .navigated, .closed])
        #expect(rig.recorded.histogram(.rendererUnresponsive)?.count == 4)
        #expect(!String(reflecting: rig.recorded.reports).contains("planted.example"), "a report names no page")
    }

    @Test func aCmuxPageInChromiumIsThePageSurface() throws {
        let rig = try CEFStabilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.pageThemeSurface = .internalPage
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        rig.runtime.handle(.renderResponsive(browser: 7))
        #expect(rig.recorded.reports.map(\.surface) == [.page])
    }

    @Test func aTabThatNeverHungRecordsNothing() throws {
        let rig = try CEFStabilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.loadStart(browser: 7, url: "https://example.com/", fromPost: false))
        rig.runtime.handle(.renderResponsive(browser: 7))
        tab.close()
        #expect(rig.recorded.reports.isEmpty)
        #expect(rig.recorded.histogram(.rendererUnresponsive) == nil)
    }

    // MARK: The reducer's endings

    @Test func theReducerNamesHowAHangEnded() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(BrowserNavigationID(rawValue: 1), url: Self.planted))
        machine.apply(.unresponsiveChanged(true))
        let hung = machine.state

        var responsive = machine
        responsive.apply(.unresponsiveChanged(false))
        #expect(BrowserTabStateMachine.unresponsiveEnd(from: hung, to: responsive.state) == .responsive)

        var ended = machine
        ended.apply(.processExited(BrowserProcessExit(reason: .crashed)))
        #expect(BrowserTabStateMachine.unresponsiveEnd(from: hung, to: ended.state) == .processEnded)

        var navigated = machine
        navigated.apply(.started(BrowserNavigationID(rawValue: 2), url: URL(string: "https://example.com/")))
        #expect(BrowserTabStateMachine.unresponsiveEnd(from: hung, to: navigated.state) == .navigated)
    }
}

// MARK: Rigs

/// A ``RendererStability`` on its own trace runtime and metrics store, with a clock the test moves and the reports it
/// sent, flattened to what a test compares.
@MainActor final class StabilityRig {
    struct Sent: Equatable {
        var kind: RendererStability.Kind
        var engine: RendererStability.Engine
        var surface: RendererStability.Surface
        var count: Int
        var milliseconds: Int64?
        var ending: RendererStability.UnresponsiveEnd?
    }

    private let uptime = Uptime()
    let store: MetricsStore
    private(set) var reports: [Sent] = []
    private(set) lazy var stability: RendererStability = RendererStability(trace: trace, clock: uptime.clock) { [weak self] report in
        self?.reports.append(Sent(kind: report.kind, engine: report.engine, surface: report.surface, count: report.count,
                                  milliseconds: report.unresponsiveMilliseconds, ending: report.ending))
    }
    private let trace = TraceRuntime(role: .app)

    init() {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.1.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27))
        store = MetricsStore(role: .app, profile: profile)
        store.attach(to: trace)
    }

    var endings: [RendererStability.UnresponsiveEnd?] { reports.map(\.ending) }

    func advance(milliseconds: UInt64) { uptime.advance(nanos: milliseconds * 1_000_000) }

    func histogram(_ id: HistogramID) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    /// `CLOCK_UPTIME_RAW` as a counter.
    private nonisolated final class Uptime: Sendable {
        private let nanos = Atomic<UInt64>(1_000_000_000)

        func advance(nanos delta: UInt64) { _ = nanos.wrappingAdd(delta, ordering: .relaxed) }

        var clock: TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in nanos.load(ordering: .relaxed) }, continuousNow: { ContinuousClock.now }))
        }
    }
}

extension StabilityRig.Sent {
    init(kind: RendererStability.Kind, engine: RendererStability.Engine, surface: RendererStability.Surface, count: Int) {
        self.init(kind: kind, engine: engine, surface: surface, count: count, milliseconds: nil, ending: nil)
    }
}

/// A runtime on a spy shim whose window creates start and whose other functions do nothing, with a test stability.
@MainActor final class CEFStabilityRig {
    let runtime: CEFRuntime
    /// What the runtime's stability events recorded.
    let recorded = StabilityRig()
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cef-renderer-stability-\(UUID().uuidString)", directoryHint: .isDirectory)
        runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(StabilitySpy.symbol), storage: CEFProfileStorage(root: root))
        runtime.rendererStability = recorded.stability
    }

    /// A tab whose browser 7 exists (AFTER_CREATED).
    func attachedTab() throws -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        try #require(tab.browserID == 7)
        return tab
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A fake fork behind the shim: fork API 29, `cmux_shim_create_window` reports the window started, every other function
/// does nothing and returns 0.
private nonisolated enum StabilitySpy {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
