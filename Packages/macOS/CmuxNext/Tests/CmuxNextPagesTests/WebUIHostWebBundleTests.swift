import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// A change of the served web files through the page host (p13-webui-071, p13-webui.md 3.C). It
/// reaches only the WebKit pages the update folder serves (a Chromium page keeps its bundled files).
/// With feature `webUpdateReloadOnShow` only the shown page is asked and reloaded; hidden and frozen
/// pages get no call and stay frozen, as Chrome loads a background tab marked `SetNeedsReload` only
/// when it is shown (content/browser/renderer_host/navigation_controller_impl.cc). Their show does not
/// reload them: it hands them to the safe point, which asks them first (``WebBundleSafePoint``), since
/// their document may hold what a reload loses. Without it every page that holds a document reloads at
/// the change. The pool's parked spare is never reloaded at the change: its claim loads the new files.
@MainActor @Suite(.serialized)
struct WebUIHostWebBundleTests {
    /// The safe point: records the pages handed to it as they show stale.
    @MainActor private final class SafePoint: WebBundleSafePoint {
        private(set) var shown: [ObjectIdentifier] = []
        func staleShown(_ page: any WebBundlePage) { shown.append(ObjectIdentifier(page)) }
    }

    private let root: URL
    private let descriptor = PageDescriptor(id: "test.web-bundle", resource: "web-bundle", processGroup: .privileged, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(chromium: FakeChromiumHosting?, reloadsOnShow: Bool) -> WebUIHost {
        let host = WebUIHost(chromium: chromium, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never)
        host.bundleReloadsOnShow = reloadsOnShow
        return host
    }

    /// `count` loaded pages in one window: the first shows, the others are hidden tabs, frozen.
    private func openPages(_ count: Int, host: WebUIHost) async throws -> (NSWindow, [PageWebView]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        var views: [PageWebView] = []
        for index in 0..<count {
            let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
            await view.chromiumStart?.value
            view.frame = container.bounds
            view.isHidden = index > 0
            container.addSubview(view)
            view.loaded = true
            if index > 0 { #expect(view.freezePage()) }
            views.append(view)
        }
        return (window, views)
    }

    private func fake(_ view: PageWebView) throws -> FakeChromiumPage {
        try #require(view.chromiumPage as? FakeChromiumPage)
    }

    private func ids(_ pages: [any WebBundlePage]) -> [ObjectIdentifier] { pages.map { ObjectIdentifier($0) } }

    /// The page's side of the change, in either engine (Chromium fakes count the calls): the shown page
    /// is asked and reloads; a frozen page gets no call, stays frozen, and reloads once at its show.
    @Test func oneShownAndFourFrozenPagesGiveOneAskAndOneReloadAndTheFrozenOnesGoToTheSafePointWhenShown() async throws {
        let host = makeHost(chromium: FakeChromiumHosting(), reloadsOnShow: true)
        let safePoint = SafePoint()
        host.bundleSafePoint = safePoint
        let (window, views) = try await openPages(5, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let shown = views[0], frozen = Array(views.dropFirst())
        #expect(views.allSatisfy { $0.chromiumPage != nil })

        // Only the shown page would reload at the swap, so only it is asked.
        #expect(views.filter { host.reloadsAtSwap($0) } == [shown])
        let asked = try fake(shown).evaluations.count
        #expect(await shown.askBundleSwap() == nil)
        #expect(try fake(shown).evaluations.count == asked + 1)

        // The change: one reload now, no call into a frozen page, which stays frozen.
        let before = try frozen.map { page -> (steps: Int, evaluations: Int, reloads: Int) in
            let engine = try fake(page)
            return (steps: engine.lifecycleSteps.count, evaluations: engine.evaluations.count, reloads: engine.reloads)
        }
        let shownReloads = try fake(shown).reloads
        #expect(host.reloadOrMarkStale(views) == 1)
        #expect(try fake(shown).reloads == shownReloads + 1)
        for (index, page) in frozen.enumerated() {
            let engine = try fake(page)
            #expect(engine.reloads == before[index].reloads, "a frozen page reloaded")
            #expect(engine.evaluations.count == before[index].evaluations, "a frozen page was called into")
            #expect(engine.lifecycleSteps.count == before[index].steps, "the change thawed a frozen page")
            #expect(page.bundleStale)
        }

        // A tab switch shows one: it thaws and goes to the safe point, which asks it before any reload;
        // its show does not reload it, and it stays stale until the safe point reloads it.
        frozen[0].isHidden = false
        #expect(safePoint.shown == ids([frozen[0]]))
        #expect(try fake(frozen[0]).reloads == before[0].reloads, "the show reloaded a page without asking it")
        #expect(frozen[0].bundleStale)
        for (index, page) in frozen.enumerated().dropFirst() {
            #expect(try fake(page).reloads == before[index].reloads && page.bundleStale)
        }
        // The safe point found it free: one reload, and a later show hands it over no more.
        frozen[0].reloadForBundle()
        #expect(try fake(frozen[0]).reloads == before[0].reloads + 1)
        frozen[0].isHidden = true
        frozen[0].isHidden = false
        #expect(try fake(frozen[0]).reloads == before[0].reloads + 1)
        #expect(safePoint.shown.count == 1)
        withExtendedLifetime(window) {}
    }

    /// A Chromium page keeps its bundled files, so a web files change never reaches it: it is not
    /// asked, not reloaded and not marked, whether hidden pages wait for their show or not.
    @Test(arguments: [true, false])
    func aChromiumPageIsNotAskedReloadedOrMarked(reloadsOnShow: Bool) async throws {
        let host = makeHost(chromium: FakeChromiumHosting(), reloadsOnShow: reloadsOnShow)
        let (window, views) = try await openPages(2, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(views.allSatisfy { $0.chromiumPage != nil && !$0.bundleServedByOverlay })
        let before = try views.map { page -> (evaluations: Int, reloads: Int) in
            let engine = try fake(page)
            return (evaluations: engine.evaluations.count, reloads: engine.reloads)
        }
        #expect(host.webBundlePages.isEmpty)
        #expect(host.bundleAskedPages.isEmpty)
        #expect(host.webBundleDidChange() == 0, "a Chromium page counted as reloaded, so the Updated note shows")
        for (index, page) in views.enumerated() {
            #expect(try fake(page).reloads == before[index].reloads, "a Chromium page reloaded")
            #expect(try fake(page).evaluations.count == before[index].evaluations, "a Chromium page was asked")
            #expect(!page.bundleStale, "a Chromium page was marked to reload at its show")
        }
        views[1].isHidden = false
        #expect(try fake(views[1]).reloads == before[1].reloads)
        withExtendedLifetime(window) {}
    }

    /// WebKit pages, which the update folder serves: with the feature only the shown one reloads now
    /// and the hidden one reloads at its show; without it both reload now and none is marked.
    @Test(arguments: [true, false])
    func webKitPagesReloadAtTheChangeOrAtTheirShow(reloadsOnShow: Bool) async throws {
        let host = makeHost(chromium: nil, reloadsOnShow: reloadsOnShow)
        let safePoint = SafePoint()
        host.bundleSafePoint = safePoint
        let (window, views) = try await openPages(2, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let shown = views[0], hidden = views[1]
        #expect(views.allSatisfy(\.bundleServedByOverlay))
        #expect(Set(ids(host.webBundlePages)) == Set(ids(views)))
        #expect(ids(host.bundleAskedPages) == ids(reloadsOnShow ? [shown] : views))

        #expect(host.webBundleDidChange() == (reloadsOnShow ? 1 : 2))
        #expect(!shown.bundleStale)
        #expect(hidden.bundleStale == reloadsOnShow)
        hidden.isHidden = false
        // Its show hands it to the safe point, which asks it before it reloads it.
        #expect(hidden.bundleStale == reloadsOnShow)
        #expect(safePoint.shown == (reloadsOnShow ? ids([hidden]) : []))
        #expect(ids(host.staleShownPages) == (reloadsOnShow ? ids([hidden]) : []))
        withExtendedLifetime(window) {}
    }

    @Test func aDiscardedPageIsNotMarkedItsRestoreLoadsTheNewFiles() async throws {
        let host = makeHost(chromium: nil, reloadsOnShow: true)
        let (window, views) = try await openPages(2, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let hidden = views[1]
        host.webBundleDidChange()
        #expect(hidden.bundleStale)
        #expect(hidden.discardPage(decoder: PageSnapshotEncoder(start: { _, done in done(nil) }, decode: { _, done in done(nil) })))
        #expect(!hidden.bundleStale, "a discarded page kept its mark and would load twice at its restore")
        #expect(!hidden.bundleHasDocument)
        host.webBundleDidChange()
        #expect(!hidden.bundleStale)
        withExtendedLifetime(window) {}
    }

    /// The pool's parked spare loaded its document when it parked: the change does not reload it (nobody
    /// sees it) but marks it, so its claim loads the new files and never keeps the old document.
    @Test(arguments: [true, false])
    func theParkedSpareIsMarkedAndItsClaimReloads(reloadsOnShow: Bool) throws {
        let registry = PageRegistry()
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), registry: registry,
                             clock: PageTestClock.never)
        host.bundleReloadsOnShow = reloadsOnShow
        let configuration = WKWebViewConfiguration()
        let spare = PageWebView(descriptor: descriptor, configuration: configuration,
                                inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                                options: .standard, surface: nil, dynamicResources: nil, pooled: true, load: false,
                                chromium: nil, registry: registry)
        defer {
            spare.close()
            try? FileManager.default.removeItem(at: root)
        }
        let parking = PageHostParking()
        parking.addSubview(spare)
        spare.loaded = true
        #expect(spare.isParkedSpare && spare.bundleParked && spare.bundleHasDocument)
        #expect(spare.claimKeepsDocument)
        #expect(ids(host.webBundlePages) == ids([spare]))
        #expect(host.bundleAskedPages.isEmpty, "the swap asked the parked spare")

        #expect(host.webBundleDidChange() == 0, "the swap reloaded the parked spare")
        #expect(spare.bundleStale)
        #expect(!spare.claimKeepsDocument, "a claim would acknowledge the document of the old files")

        // Claimed: out of the parking; the claim reloads it (``PageWebView/retarget``), not its show.
        spare.removeFromSuperview()
        #expect(spare.bundleStale && !spare.claimKeepsDocument)
    }

    /// The pool's spares are pages ``WebUIHost/open(_:)`` never makes: a claim the pool may serve arms
    /// the web-dev.json watch as an open does (``PageHostPool/willServe``), with no page opened.
    @Test func aPoolClaimWithNoOpenArmsTheDevOverrideWatch() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = PageTestMemory()
        let pool = PageHostPool(memory: memory.coordinator, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        var armed = 0
        pool.willServe = { armed += 1 }
        try #require(PageWebView.engineDecision(for: .settings, options: pool.options).engine == .webKit,
                     "Settings would open in Chromium, which the pool never serves")
        #expect(pool.claim(.settings, routes: [], window: nil) == nil, "no spare is ready")
        #expect(armed == 1, "a pool claim made no open and left web-dev.json unread")
    }
}
