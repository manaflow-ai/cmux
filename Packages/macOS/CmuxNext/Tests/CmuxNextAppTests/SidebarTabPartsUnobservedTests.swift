import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextFavicons
import CmuxNextRemoteLocalhostService
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// A KEPT PART OF A SIDEBAR ROW'S TAB DOES NOT SHOW A STALE TITLE OR FAVICON WHERE NO OBSERVATION COVERS ITS SOURCE.
///
/// A row keeps one part for each tab (`SidebarTabParts`), and a part is made again when something that its map
/// read changes. Four sources of a tab's title and favicon are not observable, so a part's own observation can not
/// hear them: a page tab's page, an incognito page's live title, a New Tab page's own title, and whether a page's
/// favicon is of another machine's store. The app gives their answers for each tab at each map of the row
/// (`SidebarTabParts.Unobserved`), and a part whose answer is another one is made again.
///
/// Each of the 4 rows here: the source changes with no change of an observed value, and the next map of the row
/// shows the new title or favicon and makes that one part. With no such answer in a part's input the 4 rows are
/// red: the kept part shows the old value.
///
/// Two rows more are of the row's page answer, which the app's title rule takes and does not ask again. For a chat
/// on the New Tab page the title rule's own page rule is asked 0 times at a map where each part is kept. For a tab
/// that is no chat that answer gives no title to compare, and the row shows what a walk shows. Both are guards.
///
/// A fifth source is the favicon loader's own cache: the favicon store hands out an icon that a page's engine put
/// there, and that cache is not observable. The input of a page's part has the loader's count of the changes of
/// its cache. That count is one for the whole cache, so one icon kept makes the part of each page of each mapped
/// row again: 3 rows, of an icon that comes, of a second icon for the same address, and of the price at 84 tabs.
///
/// Limits: the 3 title sources are the title rule's own functions, set by the test (not the app's page provider,
/// its incognito page or its history page); the incognito answer is given by the test, not by a window's
/// registry; the favicon row's page function is the test's, over the app's proxied-tabs type with a defaults suite
/// of its own. No window and no view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct SidebarTabPartsUnobservedTests {
    typealias Session = SidebarTabPartsTests.Session
    private static var runtimes: [CEFRuntime] = []

    /// The title sources that the test changes: plain values, not observable.
    @MainActor final class Source {
        var page = "Diff"
        var incognito: [String: String] = [:]
        var newTab = "New Tab"
    }

    /// What one row of this suite maps with.
    struct Row {
        var parts: SidebarTabParts
        var title: SidebarBridge.TabTitle
        var page: SidebarTabParts.Page?
    }

    /// The row's rule: the rows with kept parts show `before` for tab `tab`; then `change`; then a walk shows
    /// `after` (setup), and the next map with the kept parts shows `after`, makes `made` parts (1: the part of that
    /// tab and no other) and equals the walk.
    static func showsTheChange<Shown: Equatable>(_ session: Session, _ row: Row, tab: String, before: Shown, after: Shown, what: String, made: Int = 1,
                                                 shown: (SidebarTab) -> Shown, change: () -> Void) throws {
        func value(_ rows: [SidebarWorkspace]) -> Shown? { Session.item(tab, in: rows).map(shown) }
        let first = session.mapped(row.parts, title: row.title, page: row.page)
        try #require(first.rows == session.rows(nil, title: row.title, page: row.page), "setup: the rows with kept parts are not the walk's rows")
        try #require(value(first.rows) == before, "setup: the row shows \(String(describing: value(first.rows))) as the tab's \(what), want \(before)")
        let kept = session.mapped(row.parts, title: row.title, page: row.page)
        try #require(kept.made == 0, "setup: the second map made \(kept.made) parts, want 0")

        change()
        let walk = session.rows(nil, title: row.title, page: row.page)
        try #require(value(walk) == after, "setup: a row made now shows \(String(describing: value(walk))) as the tab's \(what) after the change, want \(after)")
        let next = session.mapped(row.parts, title: row.title, page: row.page)
        #expect(value(next.rows) == after,
                "the row shows \(String(describing: value(next.rows))) as the tab's \(what) after its source changed, want \(after): the kept part is stale")
        #expect(next.made == made, "one tab's \(what) changed and the next map made \(next.made) parts, want \(made)")
        #expect(next.rows == walk, "the rows with kept parts are not the walk's rows after the change")
    }

    /// A row that maps with the title rule `titles` in a workspace whose incognito answer is `incognito`, as the
    /// app's own functions do (the app's `SidebarTabParts.init(_:)`, `SidebarBridge.tabTitle`).
    static func row(_ session: Session, titles: TabTitleResolver, incognito: Bool) -> Row {
        let services = session.services
        let parts = SidebarTabParts(given: { _ in
            { tab, newTabPage in SidebarTabParts.Unobserved(tab, newTabPage: newTabPage, incognito: incognito, titles: titles, services) }
        })
        return Row(parts: parts, title: { _, tab in titles.title(tab, incognito: incognito) })
    }

    /// A page tab (a diff, Settings): its title is its page's, which the tab's record does not have.
    @Test func aPageTabsNewTitleShowsAtTheNextMap() throws {
        let session = try Session(tabs: 6) { tree in
            tree.workspaces[0].screens[0].panes[0].tabs[4].kind = .conversation
            tree.workspaces[0].screens[0].panes[0].tabs[4].conversation = ConversationTabRef(page: "tab-parts-page")
        }
        let tab = try #require(session.tabs.first { $0.page != nil }, "setup: the storm workspace has no page tab")
        let source = Source()
        var titles = TabTitleResolver(services: session.services)
        titles.page = { asked in asked.page != nil ? (title: source.page, icon: TabIcon.none) : nil }
        try Self.showsTheChange(session, Self.row(session, titles: titles, incognito: false), tab: tab.id, before: "Diff", after: "Settings",
                                what: "title", shown: \.title) { source.page = "Settings" }
    }

    /// An incognito workspace's page: its title is its live page's (the record of an incognito tab is a
    /// placeholder). One page of the workspace gets a title; each other page keeps its own.
    @Test func anIncognitoPagesNewTitleShowsAtTheNextMap() throws {
        let session = try Session(tabs: 6)
        let tab = try #require(session.tabs.last { $0.kind == .browser }, "setup: the storm workspace has no browser tab")
        let source = Source()
        var titles = TabTitleResolver(services: session.services)
        titles.incognitoTitle = { asked, known in
            guard asked.kind == .browser, known == true else { return nil }
            return .some(source.incognito[asked.id] ?? "Private page")
        }
        try Self.showsTheChange(session, Self.row(session, titles: titles, incognito: true), tab: tab.id, before: "Private page", after: "Bank",
                                what: "title", shown: \.title) { source.incognito[tab.id] = "Bank" }
    }

    /// A chat tab that is on the New Tab page: its title is that page's own (the page shows the history).
    @Test func aNewTabPagesNewTitleShowsAtTheNextMap() throws {
        let session = try Session(tabs: 6, blank: true) { tree in
            tree.workspaces[0].screens[0].panes[0].tabs[2].title = ""
        }
        let tab = try #require(session.tabs.first { $0.kind == .conversation && $0.agentSession?.session == nil }, "setup: the storm workspace has no blank chat")
        let source = Source()
        var titles = TabTitleResolver(services: session.services)
        titles.newTabPageTitle = { _ in source.newTab }
        try #require(titles.isNewTabPage(tab), "setup: the blank chat is not on the New Tab page")
        try Self.showsTheChange(session, Self.row(session, titles: titles, incognito: false), tab: tab.id, before: "New Tab", after: "History",
                                what: "title", shown: \.title) { source.newTab = "History" }
    }

    /// A chat tab that is on the New Tab page, in a row that has a page rule: at a map where each part is kept, the
    /// title rule takes the row's answer for each tab and does not ask its own page rule, at its guard or for the
    /// page's name. The count is of the calls of the title rule's page rule. A guard: this row was not red first.
    @Test func aRowWithAPageRuleGivesItsAnswerAndTheTitleRuleDoesNotAskItsOwn() throws {
        let session = try Session(tabs: 6, blank: true) { tree in
            tree.workspaces[0].screens[0].panes[0].tabs[2].title = ""
        }
        let tab = try #require(session.tabs.first { $0.kind == .conversation && $0.agentSession?.session == nil }, "setup: the storm workspace has no blank chat")
        let counter = SidebarTabPartsTests.Counter()
        var titles = TabTitleResolver(services: session.services)
        let rule = titles.showsNewTabPage
        titles.showsNewTabPage = { asked in
            counter.calls += 1
            return rule(asked)
        }
        titles.newTabPageTitle = { _ in "History" }
        try #require(titles.isNewTabPage(tab), "setup: the blank chat is not on the New Tab page")
        counter.calls = 0
        try #require(titles.unobservedTitle(tab, incognito: false) == "History", "setup: the title rule does not give the page's own name for the blank chat")
        try #require(counter.calls > 0, "setup: the title rule with no answer of a row did not ask its page rule: the counter counts nothing")

        let row = Self.row(session, titles: titles, incognito: false)
        let first = session.mapped(row.parts, title: row.title)
        try #require(Session.item(tab.id, in: first.rows)?.title == "History", "setup: the row does not show the page's own name for the blank chat")
        counter.calls = 0
        let kept = session.mapped(row.parts, title: row.title)
        let asked = counter.calls
        try #require(kept.made == 0, "setup: the second map made \(kept.made) parts, want 0")
        #expect(asked == 0, "a map with each part kept asked the title rule's page rule \(asked) times, want 0: the row gives its answer for each tab")
        #expect(kept.rows == session.rows(nil, title: row.title), "the rows with kept parts are not the walk's rows")
    }

    /// A tab of the row's page set that is no chat. The row gives its page answer for each tab to the title rule, and
    /// the rule's New Tab page is a chat's: for this tab the answer `true` gives no title to compare, as the rule's
    /// own answer does. The row shows what a walk shows, and a new title of the tab shows at the next map.
    @Test func aPageSetTabThatIsNoChatGetsNoTitleToCompareAndShowsTheWalksTitle() throws {
        let session = try Session(tabs: 6)
        let services = session.services
        let workspace = try #require(session.storm, "setup: the session has no storm workspace")
        let tab = try #require(session.tabs.last { $0.kind == .pty && $0.agentSession == nil }, "setup: the storm workspace has no terminal")
        services.agentTabs.pageTabs.set([(machine: services.agentTabs.daemonListing(tab)?.machineID ?? "", key: tab.id)])
        try #require(RestoredNewTabPages.shows(tab, of: workspace, in: services.agentTabs, restored: true), "setup: the row's page rule does not have the terminal")
        let titles = TabTitleResolver(services: services)
        try #require(!titles.isNewTabPage(tab), "setup: the title rule takes a terminal as a New Tab page")
        #expect(titles.unobservedTitle(tab, incognito: false, newTabPage: true) == nil,
                "the title rule gives a title to compare for a tab that is no chat, with the row's page answer `true`")

        let row = Self.row(session, titles: titles, incognito: false)
        let first = session.mapped(row.parts, title: row.title)
        #expect(first.rows == session.rows(nil, title: row.title), "the rows with kept parts are not the walk's rows")
        let kept = session.mapped(row.parts, title: row.title)
        try #require(kept.made == 0, "setup: the second map made \(kept.made) parts, want 0")
        tab.titleText = "make check"
        let walk = session.rows(nil, title: row.title)
        let next = session.mapped(row.parts, title: row.title)
        #expect(next.made == 1, "one tab's title changed and the next map made \(next.made) parts, want 1")
        #expect(next.rows == walk, "the rows with kept parts are not the walk's rows after the title changed")
    }

    /// A 1x1 image: clear, or `filled` with one color.
    static func icon(filled: Bool = false) throws -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        if filled {
            context?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try #require(context?.makeImage(), "setup: no 1x1 image")
    }

    /// A page whose favicon address is a loopback one: the app fetches it itself, and shows it, only while the
    /// tab's store is the app's own. The tab becomes a proxied tab (its store is another machine's): the next map
    /// shows no favicon. Nothing of the proxied-tabs record is observable.
    @Test func aPageThatBecomesProxiedLosesItsLoopbackFaviconAtTheNextMap() throws {
        let session = try Session(tabs: 6)
        let tab = try #require(session.tabs.last { $0.kind == .browser }, "setup: the storm workspace has no browser tab")
        let suite = "tab-parts-proxied-row-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), "setup: no defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxied = ProxiedBrowserTabs(defaults: defaults)
        let marker = SidebarFavicon(try Self.icon())
        let page: SidebarTabParts.Page = { _, asked in
            guard asked.kind == .browser else { return nil }
            let address = proxied.appFetchableFavicon("http://localhost:3000/favicon.ico", key: asked.id, page: nil)
            return SidebarMapping.PageFace(favicon: address != nil ? marker : nil)
        }
        let given: SidebarTabParts.Given = { _ in
            return { asked, _ in SidebarTabParts.Unobserved(remoteFavicon: asked.kind == .browser && proxied.faviconIsRemote(key: asked.id, page: nil)) }
        }
        let row = Row(parts: SidebarTabParts(page: page, given: given), title: { _, asked in asked.displayTitle }, page: page)
        let shows: SidebarFavicon? = marker, none: SidebarFavicon? = nil
        try Self.showsTheChange(session, row, tab: tab.id, before: shows, after: none, what: "favicon", shown: { $0.favicon }) {
            proxied.record(tab.id, store: BrowserMachineStore(machineKey: "0123456789abcdef", machineName: "box", proxyPort: 1))
        }
    }

    /// A PNG file of the 1x1 image, as a page's engine gives its favicon to the loader.
    static func png(filled: Bool = false) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: try icon(filled: filled)).representation(using: .png, properties: [:]), "setup: no PNG file of the 1x1 image")
    }

    /// A session whose pages each showed no favicon because the app's fetch failed, with the row that maps it.
    struct FailedIcons {
        let session: Session
        let row: Row
        /// The storm workspace's last page, its favicon address and its engine's profile.
        let tab: TabModel
        let url: URL
        let profile: BrowserProfileID
        /// The pages of the session's 2 workspaces: a change of the loader's icons makes the part of each again.
        let pages: Int
    }

    /// A session with a storm workspace of `tabs` tabs. The page function and the input are the app's own, over the
    /// app's favicon store and its shared loader. Each page has an `http` address on a host of its own: the loader
    /// refuses it with no request, so each fetch fails at once and the row asks no network. The map after the drain
    /// starts no second fetch: the failure is remembered.
    static func failedIcons(tabs: Int) async throws -> FailedIcons {
        let run = UUID().uuidString.lowercased()
        let session = try Session(tabs: tabs) { tree in
            for at in tree.workspaces.indices {
                for tab in tree.workspaces[at].screens[0].panes[0].tabs.indices where tree.workspaces[at].screens[0].panes[0].tabs[tab].kind == .browser {
                    tree.workspaces[at].screens[0].panes[0].tabs[tab].url = "http://page-\(at)-\(tab)-\(run).example/"
                }
            }
        }
        let services = session.services
        let tab = try #require(session.tabs.last { $0.kind == .browser }, "setup: the storm workspace has no browser tab")
        let address = try #require(SidebarMapping.favicon(tab.faviconURL, page: tab.url), "setup: the page has no favicon address")
        let url = try #require(URL(string: address), "setup: the page's favicon address is no URL")
        let profile = services.browserProfiles.engineProfile(for: tab, incognito: false)
        let titles = TabTitleResolver(services: services)
        let page: SidebarTabParts.Page = { workspace, asked in SidebarMapping.PageFace(tab: asked, of: workspace, services) }
        let given: SidebarTabParts.Given = { _ in
            { asked, newTabPage in SidebarTabParts.Unobserved(asked, newTabPage: newTabPage, incognito: false, titles: titles, services) }
        }
        let row = Row(parts: SidebarTabParts(page: page, given: given), title: { _, asked in titles.title(asked, incognito: false) }, page: page)

        // The first map asks for each page's favicon, and each fetch fails.
        _ = session.mapped(row.parts, title: row.title, page: row.page)
        await LargeSessionFixture.drainMain()
        _ = session.mapped(row.parts, title: row.title, page: row.page)
        try #require(!services.favicons.isFetching(address, profile: profile), "setup: a fetch of the page's favicon is in work after the drain, want a remembered failure")
        try #require(services.favicons.cachedImage(for: address, profile: profile) == nil, "setup: the page's favicon landed, want a failed fetch")
        let store = services.machines.local.store
        let pages = session.keys.compactMap { store.workspace(key: WorkspaceKey(rawValue: $0)) }
            .flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }.count(where: { $0.kind == .browser })
        return FailedIcons(session: session, row: row, tab: tab, url: url, profile: profile, pages: pages)
    }

    /// A page whose favicon the app could not fetch shows none while that failure is remembered. Another page of
    /// the site then loads, and its engine's own fetch puts the icon in the loader's cache: the next map of the row
    /// shows it for the first page too (#42435). The loader's cache is not observable. The loader's count is one
    /// for its whole cache, so the next map makes the part of each page of the 2 rows, and of no other tab.
    @Test func aPageWhoseFetchFailedShowsTheIconOfTheLoadersCacheAtTheNextMap() async throws {
        let fixture = try await Self.failedIcons(tabs: 6)
        // Another page's engine fetched the site's icon: it is in the loader's cache.
        let file = try Self.png()
        try Self.showsTheChange(fixture.session, fixture.row, tab: fixture.tab.id, before: false, after: true, what: "favicon", made: fixture.pages,
                                shown: { $0.favicon != nil }) {
            _ = BrowserFaviconLoader.shared.store(file, at: fixture.url, profile: fixture.profile)
        }
    }

    /// The engine of a page stores 2 different icons one after the other for ONE address (a site that changes its
    /// icon): the map after each store shows that store's icon, and makes the parts again each time. The loader
    /// decodes each stored file into an image of its own, so the count rises at each store, also of an address
    /// that it has.
    @Test func aSecondIconForTheSameAddressShowsAtTheNextMap() async throws {
        let fixture = try await Self.failedIcons(tabs: 6)
        let (session, row) = (fixture.session, fixture.row)
        func favicon(_ rows: [SidebarWorkspace]) -> SidebarFavicon? { Session.item(fixture.tab.id, in: rows)?.favicon }
        var shown: [SidebarFavicon] = []
        let files = [try Self.png(), try Self.png(filled: true)]
        try #require(files[0] != files[1], "setup: the 2 PNG files are the same bytes")
        for (at, file) in files.enumerated() {
            let kept = session.mapped(row.parts, title: row.title, page: row.page)
            try #require(kept.made == 0, "setup: the map before store \(at + 1) made \(kept.made) parts, want 0")
            try #require(BrowserFaviconLoader.shared.store(file, at: fixture.url, profile: fixture.profile) != nil, "setup: the loader did not keep icon \(at + 1)")
            let walk = session.rows(nil, title: row.title, page: row.page)
            let icon = try #require(favicon(walk), "setup: a row made now shows no favicon after store \(at + 1)")
            let next = session.mapped(row.parts, title: row.title, page: row.page)
            #expect(favicon(next.rows) == icon, "the row does not show the icon of store \(at + 1) for the page: the kept part is stale")
            #expect(next.made == fixture.pages, "store \(at + 1) of an icon for one address: the next map made \(next.made) parts, want \(fixture.pages) (each page)")
            #expect(next.rows == walk, "the rows with kept parts are not the walk's rows after store \(at + 1)")
            shown.append(icon)
        }
        try #require(shown.count == 2 && shown[0] != shown[1], "setup: the second store's icon is the first store's image: the row proves nothing of a second icon")
    }

    /// The app's own page function, asked directly (`SidebarMapping.PageFace.init(tab:of:_:)`): a page's face has the
    /// icon that the loader has for the page's address as its favicon, and a tab that is no page (a terminal, a
    /// chat) has no face, also when its record has that page's addresses. With no check of the tab's kind in the
    /// function the last part is red: each such tab gets a face.
    @Test func onlyAPageHasAFaceAndThatFaceHasThePagesFavicon() async throws {
        let fixture = try await Self.failedIcons(tabs: 6)
        let (session, services) = (fixture.session, fixture.session.services)
        let workspace = try #require(session.storm, "setup: the session has no storm workspace")
        let waits = try #require(SidebarMapping.PageFace(tab: fixture.tab, of: workspace, services), "a page has no face while its favicon is not loaded")
        try #require(waits.favicon == nil, "setup: the page's face has a favicon before the loader has the icon of its address")
        let file = try Self.png()
        try #require(BrowserFaviconLoader.shared.store(file, at: fixture.url, profile: fixture.profile) != nil, "setup: the loader did not keep the icon")
        let face = try #require(SidebarMapping.PageFace(tab: fixture.tab, of: workspace, services), "a page has no face")
        #expect(face.favicon != nil, "a page's face has no favicon after the loader kept the icon of the page's address")

        let others = session.tabs.filter { $0.kind != .browser }
        try #require(!others.isEmpty, "setup: the storm workspace has no tab that is no page")
        for other in others {
            let (url, favicon) = (other.url, other.faviconURL)
            other.url = fixture.tab.url
            other.faviconURL = fixture.tab.faviconURL
            let none = SidebarMapping.PageFace(tab: other, of: workspace, services) == nil
            other.url = url
            other.faviconURL = favicon
            #expect(none, "a tab that is no page (\(SidebarTabPartsTests.kind(other))) has a page face")
        }
    }

    /// The loader drops a profile's icons (a profile deleted, an incognito session ended): its count of changes
    /// rises, and a page's part has that count in its input, so the next map does not keep a part with a dropped
    /// icon. A loader of the test's own: the app's shared loader is not asked to drop a profile under other suites.
    @Test func theLoadersCountRisesWhenItDropsAProfilesIcons() throws {
        let loader = BrowserFaviconLoader()
        let url = try #require(URL(string: "http://dropped-\(UUID().uuidString.lowercased()).example/favicon.ico"), "setup: no address")
        let file = try Self.png()
        try #require(loader.store(file, at: url, profile: .default) != nil, "setup: the loader did not keep the icon")
        try #require(loader.cachedFavicon(at: url, profile: .default) != nil, "setup: the loader does not have the icon that it kept")
        let kept = loader.cachedFaviconChanges
        loader.forget(profile: .default)
        #expect(loader.cachedFavicon(at: url, profile: .default) == nil, "the loader has an icon of a profile that it dropped")
        #expect(loader.cachedFaviconChanges == kept + 1, "the loader's count went from \(kept) to \(loader.cachedFaviconChanges) for one drop of a profile's icons, want \(kept + 1)")
    }

    /// THE PRICE, with its count and a time report (no condition on a time): the loader's count is one for its whole
    /// cache. One icon that the loader keeps, of an address that no tab shows, makes the part of EACH page of the
    /// mapped rows again (28 of the 84 tabs of the storm workspace and the 1 page of the other workspace), and no
    /// part of a terminal or a chat. The 2 times are of one map of the window's 2 rows with the app's own page
    /// function: with each part kept, and directly after one icon was kept.
    @Test func oneIconKeptByTheLoaderMakesThePartOfEachPageAgain() async throws {
        let fixture = try await Self.failedIcons(tabs: SidebarTabPartsTests.Base.sizes[1])
        let (session, row) = (fixture.session, fixture.row)
        let other = try #require(URL(string: "http://no-tab-shows-this-\(UUID().uuidString.lowercased()).example/favicon.ico"), "setup: no address")
        let file = try Self.png()
        let rounds = 20
        var kept = Duration.zero, again = Duration.zero, made: [Int] = []
        for round in 0 ..< rounds {
            var start = ContinuousClock.now
            let before = session.mapped(row.parts, title: row.title, page: row.page)
            kept += ContinuousClock.now - start
            try #require(before.made == 0, "setup: the map before the store of round \(round) made \(before.made) parts, want 0")
            try #require(BrowserFaviconLoader.shared.store(file, at: other, profile: fixture.profile) != nil, "setup: the loader did not keep the icon")
            let walk = session.rows(nil, title: row.title, page: row.page)
            start = ContinuousClock.now
            let next = session.mapped(row.parts, title: row.title, page: row.page)
            again += ContinuousClock.now - start
            made.append(next.made)
            #expect(next.rows == walk, "the rows with kept parts are not the walk's rows after the loader kept an icon (round \(round))")
        }
        func ms(_ time: Duration) -> Double { (Double(time.components.attoseconds) / 1e15 + Double(time.components.seconds) * 1e3) / Double(rounds) }
        print("TAB-PARTS one icon kept by the favicon loader (an address that no tab shows): the next map of the window's 2 rows, a workspace of "
            + "\(session.tabs.count) tabs and one of 2 (\(fixture.pages) pages), made \(made.max() ?? -1) parts again; one map with each part kept = \(ms(kept)) ms, "
            + "the map after the icon = \(ms(again)) ms (each the mean of \(rounds) maps in the tests' build, the app's own page function; a report, no condition)")
        #expect(made == Array(repeating: fixture.pages, count: rounds),
                "one icon kept by the loader made \(made) parts again in \(rounds) rounds, want \(fixture.pages) each: the part of each page, and no other part")
    }

    private static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    /// A Chromium tab that was never created in a browser process, and its profile folder.
    private static func chromiumTab() throws -> (CEFTab, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "tab-parts-remote-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        return (CEFTab(id: .random(), profile: .default, host: host, runtime: runtime), root)
    }

    /// `ProxiedBrowserTabs.faviconIsRemote(key:page:)`: its 2 facts, each on and off. Fact 1: the tab's live page is
    /// a Chromium tab with a machine's store. Fact 2: the tab is proxied (recorded now, or kept from a launch
    /// before).
    @Test func aFaviconIsRemoteByItsPagesMachineStoreOrByAProxiedTab() throws {
        let suite = "tab-parts-proxied-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), "setup: no defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxied = ProxiedBrowserTabs(defaults: defaults)
        let machine = BrowserMachineStore(machineKey: "0123456789abcdef", machineName: "box", proxyPort: 1)
        #expect(!proxied.faviconIsRemote(key: "a", page: nil), "a tab with no page that is not proxied has a remote favicon")

        // Fact 2: the tab is proxied.
        proxied.record("a", store: machine)
        #expect(proxied.faviconIsRemote(key: "a", page: nil), "a proxied tab's favicon is not remote")
        #expect(!proxied.faviconIsRemote(key: "b", page: nil), "another tab's favicon is remote after tab `a` was recorded")
        #expect(ProxiedBrowserTabs(defaults: defaults).faviconIsRemote(key: "a", page: nil), "a tab that was proxied in a launch before has no remote favicon")
        #expect(!ProxiedBrowserTabs(defaults: defaults).faviconIsRemote(key: "b", page: nil), "a tab that was never proxied has a remote favicon after a relaunch")

        // Fact 1: the tab's live page has a machine's store.
        let mock = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        #expect(!proxied.faviconIsRemote(key: "b", page: mock), "a page that is not a Chromium tab has a remote favicon")
        let (tab, root) = try Self.chromiumTab()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!proxied.faviconIsRemote(key: "b", page: tab), "a Chromium tab with no machine's store has a remote favicon")
        tab.machineStore = machine
        #expect(proxied.faviconIsRemote(key: "b", page: tab), "a Chromium tab with a machine's store has no remote favicon")
        tab.machineStore = nil
        #expect(!proxied.faviconIsRemote(key: "b", page: tab), "a Chromium tab whose machine's store is gone has a remote favicon")
    }
}
