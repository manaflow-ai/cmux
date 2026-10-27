import CmuxNextCompat
import CmuxNextDesign
import CmuxNextMetrics
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSignposts
@testable import CmuxNextTrace
import Foundation
import Testing

/// A page's field data (p09-observability task 114): the theme bootstrap's `cmuxPagePerf` reports become
/// `webview.inp.<page>` and `webview.loaf_ms.<page>` samples with a ring instant each, and each report's
/// non-zero error count is one `webview.js_errors.<page>` sample, recorded when it arrives; a report from
/// another document or with a planted URL records nothing. Each test records into its own store and runtime.
@MainActor
struct PagePerfReportTests {
    /// The ring records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    struct Rig {
        let log = RecordLog()
        let runtime: TraceRuntime
        let store: MetricsStore
        let recorder: PagePerfRecorder

        init() {
            runtime = log.runtime()
            runtime.setCategories([.webview])
            let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0",
                                         hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16),
                                         buildUUID: Array(16 ..< 32), buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27))
            let pages: [HistogramID.Page] = [.settings, .home]
            store = MetricsStore(role: .app, profile: profile, pid: 4242,
                                 catalog: pages.flatMap { page -> [HistogramID] in [.webviewINP(page), .webviewLoAF(page), .webviewJSErrors(page)] })
            #expect(store.attach(to: runtime))
            recorder = PagePerfRecorder(metrics: CmuxNextMetrics.Metrics(runtime: runtime))
        }

        func histogram(_ id: HistogramID) -> MetricsDelta.Histogram? {
            store.totals().histograms.first { $0.name == id.name }
        }
    }

    /// What the bootstrap posts, as WebKit and the Chromium bridge hand it over (Foundation objects).
    static func body(inp: [Double] = [], loaf: [Double] = [], errors: Int = 0, extra: [String: Any] = [:]) -> Any {
        var object: [String: Any] = ["v": 1, "inp": inp, "loaf": loaf, "errors": errors]
        object.merge(extra) { _, new in new }
        return object as NSDictionary
    }

    static func message(_ body: Any, from url: String = "cmux-page://cmux.settings/index.html#/general",
                        mainFrame: Bool = true) -> PageHostMessage {
        PageHostMessage(frameURL: URL(string: url), isMainFrame: mainFrame, body: body)
    }

    @Test func aFakeBridgeMessageGivesHistogramsAndRingInstants() throws {
        let rig = Rig()
        let report = try #require(PagePerfReport(Self.message(Self.body(inp: [64, 248], loaf: [80])), from: .settings))
        rig.recorder.record(report, page: .settings)
        let inp = try #require(rig.histogram(.webviewINP(.settings)))
        #expect(inp.count == 2)
        #expect(inp.sum == 64 + 248)
        let loaf = try #require(rig.histogram(.webviewLoAF(.settings)))
        #expect(loaf.count == 1)
        #expect(loaf.sum == 80)
        let instants = rig.log.records.filter { $0.phase == .instant }
        #expect(instants.map(\.name) == [SignpostName.webviewINP.rawValue, SignpostName.webviewINP.rawValue,
                                         SignpostName.webviewLoAF.rawValue])
        #expect(instants.map(\.arg0) == Array(repeating: HistogramID.Page.settings.traceIndex, count: 3))
        #expect(instants.map(\.arg1) == [64_000, 248_000, 80_000], "the duration in us")
        #expect(rig.histogram(.webviewJSErrors(.settings)) == nil, "a report with no error adds no error sample")
    }

    @Test func aPlantedURLIsRefused() {
        let body = Self.body(inp: [300])
        #expect(PagePerfReport(Self.message(body, from: "https://example.com/"), from: .settings) == nil)
        #expect(PagePerfReport(Self.message(body, from: "cmux-page://cmux.history/index.html"), from: .settings) == nil,
                "another page's document")
        #expect(PagePerfReport(Self.message(body, mainFrame: false), from: .settings) == nil, "a subframe")
        #expect(PagePerfReport(Self.message(Self.body(inp: [300], extra: ["url": "https://example.com/"])), from: .settings) == nil)
        #expect(PagePerfReport(Self.message(Self.body(inp: [300], extra: ["page": "settings"])), from: .settings) == nil)
        #expect(PagePerfReport(Self.message(body), from: .settings) != nil)
    }

    @Test func aBodyOutsideTheReportShapeIsRefused() {
        #expect(PagePerfReport(body: Self.body(extra: ["v": 2])) == nil)
        #expect(PagePerfReport(body: Self.body(inp: [-1])) == nil)
        #expect(PagePerfReport(body: Self.body(loaf: [.infinity])) == nil)
        #expect(PagePerfReport(body: Self.body(loaf: [4_000_000])) == nil, "over an hour")
        #expect(PagePerfReport(body: Self.body(inp: Array(repeating: 20, count: PagePerfReport.maximumSamples + 1))) == nil)
        #expect(PagePerfReport(body: Self.body(extra: ["inp": ["20"]])) == nil)
        #expect(PagePerfReport(body: Self.body(extra: ["errors": 1.5])) == nil)
        #expect(PagePerfReport(body: [1] as NSArray) == nil)
        #expect(PagePerfReport(body: Self.body(inp: [20.4], loaf: [51.6], errors: 2))
            == PagePerfReport(interactions: [20], longFrames: [52], errors: 2))
    }

    @Test func scriptErrorsCountInTheTurnTheirReportArrives() throws {
        let rig = Rig()
        rig.recorder.record(PagePerfReport(interactions: [], longFrames: [], errors: 2), page: .settings)
        let first = try #require(rig.histogram(.webviewJSErrors(.settings)), "no wait for the document to end")
        #expect(first.count == 1)
        #expect(first.sum == 2)
        // The page closed (its routes ended), then its pagehide report still arrives: its errors count.
        rig.recorder.record(PagePerfReport(interactions: [40], longFrames: [], errors: 3), page: .settings)
        rig.recorder.record(PagePerfReport(interactions: [], longFrames: [70], errors: 0), page: .settings)
        let errors = try #require(rig.histogram(.webviewJSErrors(.settings)))
        #expect(errors.count == 2, "a report without errors adds no sample")
        #expect(errors.sum == 5, "the sum is the page's errors")
    }

    @Test func pageIDsComeFromTheStaticList() {
        for id in FirstPartyPages.ids {
            #expect(HistogramID.Page(pageID: id) != .other, "\(id)")
        }
        #expect(HistogramID.Page(pageID: "cmux.icon-picker") == .iconPicker)
        #expect(HistogramID.Page(pageID: "https://example.com/") == .other)
        #expect(HistogramID.Page(pageID: "cmux.stats") == .other)
    }

    @Test func thePageShownAsTheHomeSurfaceIsHome() throws {
        #expect(HistogramID.Page(pageID: "cmux.home-channels", surface: .home) == .home)
        #expect(HistogramID.Page(pageID: "cmux.home-channels") == .homeChannels)
        #expect(HistogramID.Page(pageID: "cmux.diff", surface: .diff) == .diff)
        let rig = Rig()
        rig.recorder.record(PagePerfReport(interactions: [120], longFrames: [], errors: 0),
                            page: HistogramID.Page(pageID: "cmux.home-channels", surface: .home))
        #expect(rig.histogram(.webviewINP(.home))?.count == 1)
        #expect(HistogramID.webviewINP(.home).name == "webview.inp.home")
    }

    @Test func theBootstrapPostsToTheHandlerBothEnginesListen() {
        #expect(WebTheme.bootstrapScript.contains("handlers.\(WebTheme.perfHandlerName).postMessage"))
        #expect(WebTheme.bootstrapScript.contains(">= \(WebTheme.perfReportCapacity)"))
        #expect(!WebTheme.bootstrapScript.contains("setTimeout") && !WebTheme.bootstrapScript.contains("setInterval"))
        #expect(PageWebView.chromiumFireAndForget.contains(WebTheme.perfHandlerName))
    }

    @Test func theChromiumBridgeHandsOverTheSenderSoAPlantedPageIsRefused() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: [WebTheme.perfHandlerName])
        let call = FakeChromiumPage.bindingCall(["name": WebTheme.perfHandlerName,
                                                 "body": ["v": 1, "inp": [240], "loaf": [Int](), "errors": 0] as [String: Any]])
        // What the page's view would record: the report's interactions, or "refused".
        func received(_ stage: String) async -> String? {
            await PageTestWait.value(stage) { done in
                bridge.onMessage = { _, message in
                    done(PagePerfReport(message, from: .settings).map { "\($0.interactions)" } ?? "refused")
                }
                bridge.receive(devToolsMessage: call)
            }
        }
        page.senderURL = "https://example.com/"
        #expect(await received("planted") == "refused")
        page.senderURL = "cmux-page://cmux.settings/index.html"
        #expect(await received("own") == "[240]")
    }
}
