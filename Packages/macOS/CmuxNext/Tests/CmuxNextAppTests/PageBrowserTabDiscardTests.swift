import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextApp
import CmuxNextBookmarks
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextHistory
import CmuxNextScreenshots
import CmuxNextSettings
import Foundation
import Testing

/// cmux pages in browser tabs (History, Bookmarks, Vault, Screenshots, Agent Activity) were never
/// discarded: only WebKit and Chromium pages saved a state, so the planner gave every other page
/// `canRestore = false` and a hidden History tab kept its view and model until it closed
/// (p07-memory.md 3.C, task 084). With `memoryDiscardPageTabs` each one hibernates as a web page
/// does: hidden past the timeout (or under pressure) it becomes a `HibernatedBrowserTab`, its view
/// goes, and showing it builds the page again at the same address with its view state.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PageBrowserTabDiscardTests {
    nonisolated static let addresses: [URL] = [
        HistoryPageAddress.url, BookmarkPageAddress.url, VaultPageAddress.url, ScreenshotsPageAddress.url, AgentActivityPageAddress.url,
    ]

    /// What makes a hidden page go.
    nonisolated enum Path: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Hidden past the Memory Saver timeout, no pressure.
        case timeout
        /// Critical memory pressure.
        case pressure

        var testDescription: String { rawValue }
    }

    @Test(arguments: addresses, Path.allCases)
    func aHiddenPageTabHibernatesAndShowsAgainWithItsState(_ url: URL, _ path: Path) async throws {
        let rig = Rig(path: path)
        defer { rig.close() }
        let isVault = url == VaultPageAddress.url
        // The rig shows no window, so no list lays out: the scroll stays kept until a show can apply it.
        let saved = BrowserAppPageState(url: url, scroll: BrowserAppPageState.Point(x: 0, y: 120), search: "needle")
        let key: String
        weak var oldView: NSView?
        weak var oldPage: AnyObject?
        do {
            let (opened, original) = try rig.open(url)
            key = opened
            let page = try #require(original as? any BrowserAppPage, "\(url) is not a page that can hibernate")
            #expect(page.drawsInFirstFrame == (url != AgentActivityPageAddress.url), "\(url)'s wake cover rule")
            page.restoreViewState(saved)
            oldView = original.contentView
            oldPage = original
        }
        if isVault { rig.services.vault.filter = "older" }

        rig.hide(key)
        try await rig.until("\(url) hibernated") { rig.isHibernated(key) }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.state.url == url, "the sleeping tab kept its address")
        guard case .appPage(let kept) = asleep.restoreState else {
            Issue.record("\(url) slept with no app page state")
            return
        }
        #expect(kept.scroll == saved.scroll, "\(url) slept without its scroll")
        // The page's last references go with the run loop turn that swapped it out.
        await rig.nextRunLoopTurn()
        #expect(oldView == nil && oldPage == nil, "\(url)'s view outlived its hibernation")

        // The right sidebar (or another vault tab) changes the app's one vault while this tab sleeps.
        if isVault { rig.services.vault.filter = "newer" }
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("\(url) woke") { !rig.isHibernated(key) }
        let wokenTab = try #require(rig.services.cache.browsers[key]?.tab, "the wake made no tab")
        let woken = try #require(wokenTab as? any BrowserAppPage, "the wake made no cmux page")
        #expect(wokenTab.state.url == url, "the rebuilt page shows another address")
        let shown = await woken.saveViewState()
        #expect(shown.scroll == saved.scroll, "the rebuilt \(url) lost its scroll")
        if isVault {
            #expect(shown.search == nil, "the vault page saved the shared vault's search as its own")
            #expect(rig.services.vault.filter == "newer", "the wake put an old search back on the shared vault")
        } else {
            #expect(shown.search == "needle", "the rebuilt \(url) lost its search")
        }
    }

    @Test func withTheFeatureOffAPageTabCannotHibernate() throws {
        let rig = Rig(path: .pressure, discardsAppPages: false)
        defer { rig.close() }
        let (key, _) = try rig.open(HistoryPageAddress.url)
        rig.hide(key)
        #expect(rig.hibernation.hibernateNow(key) == .unsupported)
        #expect(!rig.isHibernated(key))
    }

    @Test func aPageTabHasNoHistoryForDuplicateOrReopen() throws {
        let rig = Rig(path: .pressure)
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

    @Test func theScrollPositionWaitsForTheRowsToHoldIt() {
        let saved = Self.scrolled(to: 300)
        #expect(BrowserAppPageScroll.origin(of: saved.scroll)?.y == 300)

        let commits = Commits()
        var hasRows = false
        let rebuilt = Self.scrolled(to: 0, documentHeight: 0)
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageScroll.origin(of: saved.scroll))
        scroll.pageDidShow(list: { rebuilt.scroll }, hasRows: { hasRows })
        #expect(scroll.isWaiting, "a list too short for the position still waits")
        #expect(scroll.position(of: rebuilt.scroll)?.y == 300, "a discard before the rows came would lose the position")
        commits.fire()
        #expect(scroll.isWaiting, "a commit with no rows ended the wait")

        // The rows come and the next commit lays them out.
        hasRows = true
        rebuilt.document.setFrameSize(NSSize(width: 200, height: 1000))
        commits.fire()
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 300, "the rebuilt list did not go back to its place")
        #expect(scroll.pending == nil && !scroll.isWaiting)
        #expect(commits.waiting == 0, "the wait asked for a commit after it ended")
    }

    @Test func aListShorterThanThePositionGoesToItsEnd() {
        let commits = Commits()
        let rebuilt = Self.scrolled(to: 0, documentHeight: 400)
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 900))
        scroll.pageDidShow(list: { rebuilt.scroll }, hasRows: { true })
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 300, "a list with its rows did not go to its end")
        #expect(scroll.pending == nil)
    }

    @Test func aListBuiltAfterTheShowGetsThePosition() {
        let commits = Commits()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 250))
        scroll.pageDidShow(list: { BrowserAppPageScroll.soleScrollView(in: container) }, hasRows: { false })
        #expect(scroll.isWaiting, "a page with no list yet still waits")

        let built = Self.scrolled(to: 0)
        container.addSubview(built.scroll)
        commits.fire()
        #expect(built.scroll.documentVisibleRect.origin.y == 250)
        #expect(scroll.pending == nil)
    }

    @Test func aHideKeepsThePositionForTheNextShow() {
        let commits = Commits()
        let rebuilt = Self.scrolled(to: 0, documentHeight: 0)
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 250))
        scroll.pageDidShow(list: { rebuilt.scroll }, hasRows: { false })
        scroll.pageDidHide()
        #expect(!scroll.isWaiting, "a hidden page still waits for its rows")
        #expect(scroll.pending != nil, "the hide lost the position")
        rebuilt.document.setFrameSize(NSSize(width: 200, height: 1000))
        commits.fire()
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 0, "a hidden page's old wait scrolled it")

        scroll.pageDidShow(list: { rebuilt.scroll }, hasRows: { true })
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 250, "the next show did not apply the kept position")
        #expect(scroll.pending == nil)
    }

    @Test func thePersonsScrollEndsTheWait() {
        let commits = Commits()
        let rebuilt = Self.scrolled(to: 0, documentHeight: 200)
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 300))
        scroll.pageDidShow(list: { rebuilt.scroll }, hasRows: { false })
        #expect(scroll.isWaiting, "a list too short for the position still waits")
        // The person scrolls the list before it grows.
        rebuilt.scroll.contentView.scroll(to: NSPoint(x: 0, y: 50))
        rebuilt.scroll.reflectScrolledClipView(rebuilt.scroll.contentView)
        rebuilt.document.setFrameSize(NSSize(width: 200, height: 1000))
        commits.fire()
        #expect(scroll.pending == nil, "the wait outlived the person's scroll")
        #expect(rebuilt.scroll.documentVisibleRect.origin.y == 50, "the restore moved a list the person scrolled")
    }

    @Test func aListThatNeverGrowsEndsTheWait() {
        let commits = Commits()
        let empty = Self.scrolled(to: 0, documentHeight: 0)
        let scroll = BrowserAppPageScroll(afterCommit: commits.after)
        scroll.restore(BrowserAppPageState.Point(x: 0, y: 300))
        scroll.pageDidShow(list: { empty.scroll }, hasRows: { false })
        for _ in 0..<BrowserAppPageScroll.commitLimit { commits.fire() }
        #expect(!scroll.isWaiting && scroll.pending == nil, "an empty page waits at every commit forever")
        #expect(commits.waiting == 0)
    }

    /// The Bookmarks page holds its folder sidebar (a `ScrollView`) before its bookmark list (a
    /// `List`, a table): the list is named, not the first scroll view found.
    @Test func aPageNamesItsListNotTheFirstScrollView() {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let sidebar = Self.scrolled(to: 0).scroll
        let list = NSScrollView(frame: NSRect(x: 200, y: 0, width: 200, height: 100))
        list.documentView = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        page.addSubview(sidebar)
        page.addSubview(list)
        #expect(BrowserAppPageScroll.listScrollView(in: page) === list)
        #expect(BrowserAppPageScroll.soleScrollView(in: page) == nil, "two scroll views named one at random")
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

    /// The commits a ``BrowserAppPageScroll`` waits for, fired by hand.
    @MainActor final class Commits {
        private var bodies: [@MainActor () -> Void] = []
        var waiting: Int { bodies.count }

        var after: BrowserAppPageScroll.AfterCommit { { [weak self] body in self?.bodies.append(body) } }

        /// One commit: runs what waited for it.
        func fire() {
            let due = bodies
            bodies = []
            for body in due { body() }
        }
    }

    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = Pane()
        private var tabs: [String: TabModel] = [:]
        private static var nextSurface: UInt64 = 8_400
        /// Hibernation's own events: a page went to sleep, a woken page mounted.
        private let events: AsyncStream<Void>
        private let eventSink: AsyncStream<Void>.Continuation

        init(path: Path, discardsAppPages: Bool = true) {
            _ = NSApplication.shared
            let stream = AsyncStream<Void>.makeStream()
            events = stream.stream
            eventSink = stream.continuation
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
            services.cache.hibernation = hibernation
            hibernation.discardsAppPages = discardsAppPages
            let sink = eventSink
            hibernation.onHibernate = { sink.yield() }
            hibernation.onWakeMounted = { _ in sink.yield() }
            switch path {
            case .timeout:
                hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.000_1), freezeSeconds: nil))
            case .pressure:
                hibernation.apply(BrowserHibernationSetting(mode: .moderate))
                hibernation.pressureDidChange(.critical)
            }
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

        /// Returns once `condition` holds: now, or at a hibernation event (a sleep, a woken mount)
        /// after which it does, within 15 s.
        func until(_ what: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
            let events = events
            let met: Bool
            do {
                met = try await ControlDeadline.shared.run(method: "test.pageDiscard", deadline: .now + .seconds(15)) { @MainActor in
                    if condition() { return true }
                    for await _ in events where condition() { return true }
                    return false
                }
            } catch {
                Issue.record("\(what) never happened: \(error)")
                throw error
            }
            try #require(met, "\(what) never happened")
        }

        /// Returns at the main run loop's next turn.
        func nextRunLoopTurn() async {
            await withCheckedContinuation { (turned: CheckedContinuation<Void, Never>) in RunLoop.main.perform { turned.resume() } }
        }

        func close() {
            eventSink.finish()
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
