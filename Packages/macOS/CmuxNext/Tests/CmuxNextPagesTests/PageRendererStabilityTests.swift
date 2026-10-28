import AppKit
import CmuxNextMetrics
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// p09-observability-108 for cmux pages: a page's WebKit content-process end is one `page` stability event when its
/// host has the app's stability events, and its crash recovery runs as before. A Chromium renderer end is not one
/// here (`cef.helper_exit` counts it, task 060), and a host without stability events records nothing.
@MainActor @Suite(.serialized)
struct PageRendererStabilityTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.renderer-stability", resource: "renderer-stability", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-renderer-stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private final class Reports {
        var surfaces: [RendererStability.Surface] = []
    }

    private func host(_ stability: RendererStability?) -> WebUIHost {
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
        host.rendererStability = stability
        return host
    }

    private static func store(on trace: TraceRuntime) -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.1.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27))
        let store = MetricsStore(role: .app, profile: profile)
        store.attach(to: trace)
        return store
    }

    @Test func aPagesWebKitEndIsOnePageEventAndItStillRecovers() throws {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let reports = Reports()
        let host = host(RendererStability(trace: trace) { reports.surfaces.append($0.surface) })
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer {
            host.close(view)
            try? FileManager.default.removeItem(at: root)
        }
        let webView = try #require(view.webKitEngine)

        view.webViewWebContentProcessDidTerminate(webView)
        view.webViewWebContentProcessDidTerminate(webView)

        #expect(reports.surfaces == [.page], "two ends in a minute: one report")
        #expect(store.delta().histograms.first { $0.name == HistogramID.stabilityChildExit(.webkit).name }?.count == 2)
        #expect(view.crash.reloads == 2, "the crash recovery reloads the page as before")
    }

    @Test func twoGroupedPagesOfOneEndedProcessAreOneProcessEnd() throws {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let host = host(RendererStability(trace: trace))
        let first = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let second = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer {
            host.close(first)
            host.close(second)
            try? FileManager.default.removeItem(at: root)
        }
        // Both committed in one shared WebContent process (``WebProcessGroups``); WebKit tells each page it ended.
        first.crash.webKitCommitted(in: 4242)
        second.crash.webKitCommitted(in: 4242)

        first.webViewWebContentProcessDidTerminate(try #require(first.webKitEngine))
        second.webViewWebContentProcessDidTerminate(try #require(second.webKitEngine))

        let histograms = store.delta().histograms
        #expect(histograms.first { $0.name == HistogramID.stabilityChildExit(.webkit).name }?.count == 1, "one process ended")
        #expect(histograms.first { $0.name == HistogramID.stabilityRenderer(.contentEnd, .webkit).name }?.count == 2, "two pages lost it")
    }

    /// A preloaded page (``PagePreloadSlot``) runs a WebContent process before any claim: it opens
    /// through its host, so its end is a `page` event too.
    @Test func aPreloadedPagesContentEndBeforeAnyClaimIsOnePageEvent() throws {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let reports = Reports()
        let rig = LifecycleDeadlineRig()
        let window = PagePreloadPageTests.shownWindow()
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let host = host(RendererStability(trace: trace) { reports.surfaces.append($0.surface) })
        let slot = PagePreloadSlot(parkState: .frozenHidden, deadlines: rig.scheduler)
        host.preload = slot
        var made: PageWebView?
        let held = slot.preload(PagePreloadSlot.Key("page.stability"), size: NSSize(width: 800, height: 600), in: parking) { _ in
            made = host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], parked: true))
            return made
        }
        let preloaded = try #require(made)
        defer {
            host.close(preloaded)
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        try #require(held && preloaded.isPooled && !preloaded.isClaimed)

        preloaded.webViewWebContentProcessDidTerminate(try #require(preloaded.webKitEngine))

        #expect(reports.surfaces == [.page])
        #expect(store.delta().histograms.first { $0.name == HistogramID.stabilityRenderer(.contentEnd, .webkit).name }?.count == 1)
    }

    @Test func aChromiumEndOrAHostWithoutStabilityRecordsNothing() throws {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let reports = Reports()
        let reporting = host(RendererStability(trace: trace) { reports.surfaces.append($0.surface) })
        let silent = host(nil)
        let page = try #require(reporting.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let other = try #require(silent.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer {
            reporting.close(page)
            silent.close(other)
            try? FileManager.default.removeItem(at: root)
        }

        page.contentProcessTerminated() // the Chromium engine's renderer end reaches the page this way
        other.webViewWebContentProcessDidTerminate(try #require(other.webKitEngine))

        #expect(reports.surfaces.isEmpty)
        #expect(store.delta().isEmpty)
    }
}
