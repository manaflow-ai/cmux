import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// No cmux page renderer before the page first shows (p07-memory-048, feature `pageRendererAtFirstShow`).
/// A page the host opens with ``WebUIHost/startsPagesAtFirstShow`` starts no WebKit document and asks
/// for no Chromium page until it is in a window with no hidden ancestor; the spare Settings host is
/// made only after a pooled page was made visible (Chrome's `kPreloadOnMakeVisible`).
@MainActor @Suite(.serialized)
struct PageLazinessTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-laziness", resource: "page-laziness", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-laziness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hosting: FakeChromiumHosting?, lazy: Bool = true) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil,
                  memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                  clock: PageTestClock.never, startsPagesAtFirstShow: lazy)
    }

    @Test func aWebKitPageStartsNoDocumentBeforeItsFirstShow() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        defer { host.close(view) }
        #expect(view.awaitsFirstShow)
        #expect(view.webKitView.url == nil, "the hidden page loaded, which starts its WebContent process")
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(!view.awaitsFirstShow)
        #expect(view.webKitView.url == descriptor.url(route: "#/start"))
    }

    @Test func aChromiumPageAsksForNoRendererBeforeItsFirstShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        defer { host.close(view) }
        #expect(view.engineDecision == .chromium)
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty, "the hidden page made a Chromium page, which starts a renderer")
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(hosting.made.count == 1)
        #expect(page.loaded == [descriptor.url(route: "#/start")])
    }

    /// A tab of a hidden pane or workspace is in the window under a hidden ancestor: not shown yet.
    @Test func aPageUnderAHiddenAncestorStartsWhenTheAncestorShows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        pane.isHidden = true
        window.contentView?.addSubview(pane)
        pane.addSubview(view)
        #expect(view.awaitsFirstShow)
        #expect(view.webKitView.url == nil)
        pane.isHidden = false
        #expect(!view.awaitsFirstShow)
        #expect(view.webKitView.url == descriptor.url())
    }

    /// The host moved the page before it showed: the first show loads the last route asked for.
    @Test func aRouteOpenedBeforeTheFirstShowIsTheOneThatLoads() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/a")))
        defer { host.close(view) }
        view.open(route: "/b")
        view.reload()
        #expect(view.webKitView.url == nil, "a route or reload before the first show loaded the hidden page")
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.webKitView.url == descriptor.url(route: "#/b"))
    }

    @Test func aPageClosedBeforeItShowedNeverStarts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        host.close(view)
        #expect(!view.awaitsFirstShow)
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty)
    }

    /// With the feature off a page starts as it opens, as before.
    @Test func withoutTheFeatureAPageStartsAsItOpens() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(!view.awaitsFirstShow)
        #expect(view.webKitView.url == descriptor.url())
    }

    /// The launch's `noteLikely()` makes no Settings spare until a pooled page was made visible.
    @Test func theSettingsSpareWaitsForAPooledPageToShow() throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                policy: PageHostPool.Policy(preloadOnMakeVisible: true), activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(!pool.shouldBuild, "the launch made a spare page nobody opened")
        #expect(pool.hostCount == 0 && !pool.isBuilding)
        #expect(pool.claim(.settings, routes: [], window: window) == nil, "no spare to claim yet")
        #expect(pool.shouldBuild, "a shown Settings page arms the next spare")
    }

    /// With the feature off the launch's `noteLikely()` arms the spare, as before.
    @Test func withoutTheFeatureTheLaunchArmsTheSpare() {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(pool.shouldBuild)
    }
}
