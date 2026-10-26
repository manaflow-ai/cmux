import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// cmux pages in browser tabs (History, Bookmarks, Vault, Screenshots, Agent Activity) were never
/// discarded: only WebKit and Chromium pages saved a state, so the planner gave every other page
/// `canRestore = false` and a hidden History tab kept its view and model until it closed
/// (p07-memory.md 3.C, task 084). With `memoryDiscardPageTabs` each one hibernates as a web page
/// does: hidden under pressure it becomes a `HibernatedBrowserTab`, its view goes, and showing it
/// builds the page again at the same address with its view state.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PageBrowserTabDiscardTests {
    nonisolated static let addresses: [URL] = [
        HistoryPageAddress.url, BookmarkPageAddress.url, VaultPageAddress.url, ScreenshotsPageAddress.url, AgentActivityPageAddress.url,
    ]

    @Test(arguments: addresses) func aHiddenPageTabHibernatesAndShowsAgainWithItsState(_ url: URL) async throws {
        let rig = Rig()
        defer { rig.close() }
        let key: String
        weak var oldView: NSView?
        weak var oldPage: AnyObject?
        do {
            let (opened, original) = try rig.open(url)
            key = opened
            let page = try #require(original as? any BrowserAppPage, "\(url) is not a page that can hibernate")
            page.restoreViewState(BrowserAppPageState(url: url, search: "needle"))
            oldView = original.contentView
            oldPage = original
        }

        rig.hide(key)
        try await rig.until("\(url) hibernated") { rig.isHibernated(key) }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.state.url == url, "the sleeping tab kept its address")
        try await rig.until("\(url)'s view went") { oldView == nil && oldPage == nil }

        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("\(url) woke") { !rig.isHibernated(key) }
        let woken = try #require(rig.services.cache.browsers[key]?.tab as? any BrowserAppPage, "the wake made no cmux page")
        #expect(woken.state.url == url, "the rebuilt page shows another address")
        #expect(woken.saveViewState().search == "needle", "the rebuilt page lost its search")
    }

    @Test func withTheFeatureOffAPageTabCannotHibernate() throws {
        let rig = Rig(discardsAppPages: false)
        defer { rig.close() }
        let (key, _) = try rig.open(HistoryPageAddress.url)
        rig.hide(key)
        #expect(rig.hibernation.hibernateNow(key) == .unsupported)
        #expect(!rig.isHibernated(key))
    }

    @Test func aPageTabHasNoHistoryForDuplicateOrReopen() throws {
        let rig = Rig()
        defer { rig.close() }
        let (_, page) = try rig.open(BookmarkPageAddress.url)
        #expect(BrowserRestoreState.history(of: page) == nil, "Duplicate Tab would restore an engine history from a cmux page")
        guard case .appPage(let saved)? = (page as? any BrowserHibernationSource)?.hibernationState() else {
            Issue.record("a cmux page saved no app page state")
            return
        }
        #expect(saved.url == BookmarkPageAddress.url)
    }

    // MARK: Scroll

    @Test func theScrollPositionWaitsForTheDocumentToHoldIt() {
        let saved = Self.scrolled(to: 300)
        #expect(BrowserAppPageScroll.origin(in: saved.container)?.y == 300)

        // The test's own center: AppKit's frame notices go to the default one, the test posts the one it needs.
        let center = NotificationCenter()
        let rebuilt = Self.scrolled(to: 0, documentHeight: 0)
        let scroll = BrowserAppPageScroll(center: center)
        scroll.restore(BrowserAppPageScroll.origin(in: saved.container))
        scroll.pageDidShow(rebuilt.container)
        #expect(scroll.pending != nil, "a document too short for the position still waits")
        rebuilt.document.setFrameSize(NSSize(width: 200, height: 1000))
        center.post(name: NSView.frameDidChangeNotification, object: rebuilt.document)
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 300, "the rebuilt list did not go back to its place")
        #expect(scroll.pending == nil)
    }

    @Test func aPageShownBeforeItsListExistsGetsThePositionAtTheNextShow() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scroll = BrowserAppPageScroll(center: NotificationCenter())
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 250))
        scroll.pageDidShow(container)
        #expect(scroll.pending != nil)
        scroll.pageDidHide()
        let built = Self.scrolled(to: 0)
        container.addSubview(built.scroll)
        scroll.pageDidShow(container)
        #expect(built.scroll.documentVisibleRect.origin.y == 250)
    }

    @Test func thePersonsScrollEndsTheWait() {
        let center = NotificationCenter()
        let rebuilt = Self.scrolled(to: 0, documentHeight: 200)
        let scroll = BrowserAppPageScroll(center: center)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 300))
        scroll.pageDidShow(rebuilt.container)
        #expect(scroll.pending != nil, "a document too short for the position still waits")
        // The person scrolls the list before it grows.
        rebuilt.scroll.contentView.scroll(to: NSPoint(x: 0, y: 50))
        rebuilt.scroll.reflectScrolledClipView(rebuilt.scroll.contentView)
        rebuilt.document.setFrameSize(NSSize(width: 200, height: 1000))
        center.post(name: NSView.frameDidChangeNotification, object: rebuilt.document)
        #expect(scroll.pending == nil, "the wait outlived the person's scroll")
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 50, "the restore moved a list the person scrolled")
    }

    // MARK: Agent Activity

    @Test func agentActivityStopsItsPushesWhenItsPageGoes() {
        let source = FollowingSource()
        let model = AgentActivityModel(source: source)
        model.start()
        model.select(session: "s1")
        #expect(source.follows["s1"] == true)
        model.stop()
        #expect(source.follows["s1"] == false, "the host still sends the discarded page's events")
        #expect(source.stopped, "the host still pushes sessions to the discarded page")
    }

    // MARK: Helpers

    /// A container holding a 200 x 100 scroll view over a flipped document `documentHeight` tall,
    /// scrolled to `y`.
    static func scrolled(to y: Double, documentHeight: Double = 1000) -> (container: NSView, scroll: NSScrollView, document: NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scroll = NSScrollView(frame: container.bounds)
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: documentHeight))
        scroll.documentView = document
        container.addSubview(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (container, scroll, document)
    }

    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = Pane()
        private var tabs: [String: TabModel] = [:]
        private static var nextSurface: UInt64 = 8_400

        init(discardsAppPages: Bool = true) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry())
            services.cache.hibernation = hibernation
            hibernation.discardsAppPages = discardsAppPages
            hibernation.apply(BrowserHibernationSetting(mode: .moderate))
            hibernation.pressureDidChange(.critical)
            services.cache.findTab = { [weak self] key in self?.tabs[key] }
        }

        /// A browser tab whose record is `url`, with its cmux page installed and shown.
        func open(_ url: URL) throws -> (String, any BrowserTab) {
            Self.nextSurface += 1
            let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: Self.nextSurface), kind: .browser, url: url.absoluteString))
            tabs[tab.id] = tab
            let entry = try #require(services.cache.appPage(for: tab, url: url), "\(url) made no page")
            services.cache.present(tab.id, by: pane, presence: .visible)
            try #require(services.cache.phase(of: tab.id) == .mountedVisible)
            return (tab.id, entry.tab)
        }

        func hide(_ key: String) {
            services.cache.withdraw(key, by: pane)
        }

        func isHibernated(_ key: String) -> Bool { services.cache.browsers[key]?.tab is HibernatedBrowserTab }

        func until(_ what: @autoclosure () -> String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what()) never happened")
        }

        func close() {
            for key in tabs.keys { services.cache.release(key) }
            hibernation.stop()
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Records what the model asks of its host.
@MainActor private final class FollowingSource: AgentActivitySource {
    var follows: [String: Bool] = [:]
    var stopped = false

    func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {}
    func follow(session: String, _ on: Bool) { follows[session] = on }
    func image(for frame: AgentActivityFrameRef) async -> NSImage? { nil }
    func perform(_ op: AgentActivityUserOp) async throws {}
    func stop() { stopped = true }
}
