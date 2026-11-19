import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextFavicons
import CmuxNextRemoteLocalhostService
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Observation
import Testing

/// WHAT A SIDEBAR ROW DOES AT A MAP WHERE EACH OF ITS TABS' PARTS IS KEPT (`SidebarTabParts`).
///
/// A row keeps one part for each tab, and a tab that changes makes its own part again (`TabPartsKeptTests`). These
/// rows are about the work that stays in the row at each of its maps, and about what a kept part can hide:
///
/// - The row's own observation reads a fixed set of fields of each tab (the registration row): the count for one
///   tab is the same in a workspace of 6 tabs and of 84 tabs.
/// - The count of the calls of the page rule at one map.
/// - A part that is kept shows a title that changes (the tab's own record, with the same input).
/// - One favicon that lands makes the part of each page of the workspace again (a limit, with its count).
/// - A report with no condition: the time of what the app gives for each tab at each map.
///
/// The rows of a window are mapped here by the app's own mapping with no row feed: each call maps each row now.
/// Each row of a test is compared with a walk: the same rows made with no kept part.
///
/// Limits: no window and no view. The page function of these rows is the test's (the app's own reads the favicon
/// store, which fetches). The registration row probes a fixed list of 13 fields with plain values; the fields of
/// other types (the kind, the chat, the app, the presence, the agent state, a program's status, a notification)
/// are not probed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct SidebarTabPartsTests {
    typealias Base = TabPartsKeptTests
    /// The name of the count of the tab parts that a row's map made (``ObservationWork``).
    nonisolated static let step = "SidebarMapping.tabItems"

    /// A session of 2 workspaces in an app's local store, connected: the storm workspace (a terminal, a page and
    /// a chat in turn) and one workspace of 2 tabs.
    @MainActor final class Session {
        let services: AppServices
        let state: WindowState
        let keys: [String]

        /// - Parameters:
        ///   - tabs: The storm workspace's tabs.
        ///   - blank: Its first chat has no session yet (it shows the New Tab page).
        ///   - change: A change of the session's tree before the store gets it.
        init(tabs: Int, blank: Bool = false, change: (inout DaemonTree) -> Void = { _ in }) throws {
            _ = NSApplication.shared
            let keys = Base.keys(2)
            let services = AppServices(environment: AppEnvironment.current([:]))
            services.agentTabs.localHost = Base.host
            var tree = Base.tree(keys, storm: tabs, chats: true, blank: blank)
            change(&tree)
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: tree)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"tab-parts-rows","workspace_key":"tab-parts-rows-home"}"#.utf8))
            let state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = keys
            (self.keys, self.services, self.state) = (keys, services, state)
        }

        /// The storm workspace.
        var storm: WorkspaceModel? { services.machines.local.store.workspace(key: WorkspaceKey(rawValue: Base.storm)) }
        /// The storm workspace's tabs, in pane order.
        var tabs: [TabModel] { storm?.screens.flatMap(\.panes).flatMap(\.tabs) ?? [] }

        /// Gives the storm workspace `tabs` tabs.
        func resize(_ tabs: Int) {
            services.machines.local.store.apply(snapshot: Base.tree(keys, storm: tabs, chats: true))
        }

        /// The window's rows, each mapped now. `parts`: what the window keeps of its rows' tabs; nil: a walk (each
        /// part made now). `title`: the tab list's title of a tab. `page`: a page's face.
        func rows(_ parts: SidebarTabParts?, title: @escaping SidebarBridge.TabTitle, page: SidebarTabParts.Page? = nil) -> [SidebarWorkspace] {
            SidebarBridge.sections(services.machines, doc: services.sidebarDoc, members: keys, profile: state.profileID,
                                   rowNewTabPages: services.agentTabs, pageFace: { workspace, tab, _ in page?(workspace, tab) },
                                   tabTitle: title, tabs: parts).flatMap(\.workspaces)
        }

        /// ``rows(_:title:page:)`` with `parts`, and the count of the tab parts that the maps made.
        func mapped(_ parts: SidebarTabParts, title: @escaping SidebarBridge.TabTitle,
                    page: SidebarTabParts.Page? = nil) -> (rows: [SidebarWorkspace], made: Int) {
            let work = ObservationWork()
            let rows = ObservationWork.$current.withValue(work) { self.rows(parts, title: title, page: page) }
            return (rows, work.byStep[SidebarTabPartsTests.step] ?? 0)
        }

        /// The item of tab `id` in the storm workspace's row among `rows` (the only row with more than 2 tabs).
        static func item(_ id: String, in rows: [SidebarWorkspace]) -> SidebarTab? {
            rows.first { $0.tabs.count > 2 }?.tabs.first { $0.id.rawValue == id }
        }
    }

    /// Set by a change callback, which is not isolated.
    nonisolated final class Heard: Sendable {
        private let state = Mutex(false)
        var value: Bool { state.withLock { $0 } }
        func hear() { state.withLock { $0 = true } }
    }

    /// The fields of a tab that the registration row probes: each has a plain value.
    nonisolated enum Field: String, CaseIterable, Sendable {
        case titleText, name, cwd, url, gitBranch, gitDetached, faviconURL, dead, pinned, lastOutputMs, promptSinceMs, userIcon, formerLocalHosts
    }

    /// Gives `field` of `tab` another value, and returns what puts the old value back.
    static func change(_ field: Field, of tab: TabModel) -> @MainActor () -> Void {
        switch field {
        case .titleText: let old = tab.titleText; tab.titleText = old + " probe"; return { tab.titleText = old }
        case .name: let old = tab.name; tab.name = (old ?? "") + "probe"; return { tab.name = old }
        case .cwd: let old = tab.cwd; tab.cwd = (old ?? "") + "/probe"; return { tab.cwd = old }
        case .url: let old = tab.url; tab.url = (old ?? "https://probe.example") + "/probe"; return { tab.url = old }
        case .gitBranch: let old = tab.gitBranch; tab.gitBranch = (old ?? "") + "probe"; return { tab.gitBranch = old }
        case .gitDetached: let old = tab.gitDetached; tab.gitDetached = !old; return { tab.gitDetached = old }
        case .faviconURL: let old = tab.faviconURL; tab.faviconURL = (old ?? "https://probe.example") + "/probe.png"; return { tab.faviconURL = old }
        case .dead: let old = tab.dead; tab.dead = !old; return { tab.dead = old }
        case .pinned: let old = tab.pinned; tab.pinned = !old; return { tab.pinned = old }
        case .lastOutputMs: let old = tab.lastOutputMs; tab.lastOutputMs = (old ?? 0) + 7; return { tab.lastOutputMs = old }
        case .promptSinceMs: let old = tab.promptSinceMs; tab.promptSinceMs = (old ?? 0) + 7; return { tab.promptSinceMs = old }
        case .userIcon: let old = tab.userIcon; tab.userIcon = (old ?? "") + "probe"; return { tab.userIcon = old }
        case .formerLocalHosts: let old = tab.formerLocalHosts; tab.formerLocalHosts = ["probe": "probe"]; return { tab.formerLocalHosts = old }
        }
    }

    /// The name of a tab's kind in the registration row's print.
    static func kind(_ tab: TabModel) -> String {
        tab.agentSession != nil ? "chat" : tab.kind == .browser ? "page" : "terminal"
    }

    /// For each tab of the storm workspace: the probed fields that the row's own observation is registered on
    /// after a map where each part is kept, as one text (`dead+formerLocalHosts`).
    ///
    /// One round for each tab and each field: a map that makes each part, then a map under an observation (it makes
    /// no part), then the end of each kept part's observation (the row's cell does not move), then the field gets
    /// another value. The observation hears the change only where the row itself read that field of that tab.
    static func registrations(_ session: Session, parts: SidebarTabParts, title: @escaping SidebarBridge.TabTitle) throws -> [(kind: String, fields: String)] {
        let workspace = try #require(session.storm, "setup: the session has no storm workspace")
        var heardBy: [(kind: String, fields: String)] = []
        for tab in session.tabs {
            var fields: [String] = []
            for field in Field.allCases {
                _ = session.rows(parts, title: title)
                let heard = Heard()
                let work = ObservationWork()
                withObservationTracking {
                    ObservationWork.$current.withValue(work) { _ = session.rows(parts, title: title) }
                } onChange: {
                    heard.hear()
                }
                try #require((work.byStep[step] ?? 0) == 0, "setup: the map under the observation made \(work.byStep[step] ?? 0) parts, want 0: each part is kept")
                _ = parts.kept.parts(of: workspace, []) { (_: TabModel) -> SidebarTabParts.Part in preconditionFailure("no tab is listed") }
                try #require(!heard.value, "setup: the row's observation heard the end of its kept parts' observations")
                let back = change(field, of: tab)
                if heard.value { fields.append(field.rawValue) }
                back()
            }
            heardBy.append((kind(tab), fields.isEmpty ? "none" : fields.joined(separator: "+")))
        }
        return heardBy
    }

    /// THE REGISTRATION ROW, a guard: the row's own observation at a map where each part is kept. A tab that is
    /// not one of the row's picks (the front tab, the tab that names the row, its agent) costs the row the same
    /// registrations in a workspace of 6 tabs and of 84 tabs, and the count for one tab does not grow: a new read
    /// of each tab in the row's map shows here as another set.
    @Test func theRowsOwnObservationReadsAFixedSetOfFieldsOfEachKeptTab() throws {
        let session = try Session(tabs: Base.sizes[0])
        let title = SidebarBridge.tabTitle(session.services)
        let parts = SidebarTabParts(given: SidebarTabParts(session.services).given)
        var totals: [Int] = [], byKind: [[String: [String: Int]]] = []
        for size in Base.sizes {
            session.resize(size)
            try #require(session.tabs.count == size, "setup: the storm workspace has \(session.tabs.count) tabs, want \(size)")
            let heard = try Self.registrations(session, parts: parts, title: title)
            var sets: [String: [String: Int]] = [:]
            for tab in heard { sets[tab.kind, default: [:]][tab.fields, default: 0] += 1 }
            totals.append(heard.reduce(0) { $0 + ($1.fields == "none" ? 0 : $1.fields.split(separator: "+").count) })
            byKind.append(sets)
            let text = sets.keys.sorted().map { kind in
                "\(kind): " + (sets[kind] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.value) x [\($0.key)]" }.joined(separator: ", ")
            }.joined(separator: "; ")
            print("TAB-PARTS registrations of the row's own observation, a workspace of \(size) tabs with each part kept: \(totals[totals.count - 1]) "
                + "on the \(Field.allCases.count) probed fields; by the tab's kind: \(text)")
            #expect(heard.allSatisfy { $0.fields.split(separator: "+").contains("dead") },
                    "the probe did not hear `dead` for each tab at \(size) tabs: the row's presence walk reads it of each tab")
        }
        // The set of most tabs of a kind at the large size: what one more tab of that kind costs the row.
        var common: [String: String] = [:], growth = 0
        for (kind, sets) in byKind[1] {
            let most = sets.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "none"
            common[kind] = most
            let count = most == "none" ? 0 : most.split(separator: "+").count
            growth += count * ((sets.values.reduce(0, +)) - (byKind[0][kind]?.values.reduce(0, +) ?? 0))
        }
        #expect(common == ["terminal": "dead", "page": "dead", "chat": "dead+formerLocalHosts"],
                "the row's own observation is registered on \(common) of one tab that is not a pick, want `dead` (and the chat's host list for a chat)")
        #expect(totals[1] - totals[0] == growth,
                "the registrations grew by \(totals[1] - totals[0]) from \(Base.sizes[0]) to \(Base.sizes[1]) tabs, want \(growth): the set of one tab for each tab more, and the same count for the picks")
    }

    @MainActor final class Counter {
        var calls = 0
    }

    /// The count of the calls of the page rule at one map of a workspace of 84 tabs (28 chats, each with a session)
    /// where each part is kept. The count is of the calls of `AgentTabStore.daemonListing` for the workspace's
    /// tabs: the row's own page set asks it one time for each tab, and each call of the page rule
    /// (`RestoredNewTabPages.shows(_:in:workspace:)`) for a chat with a session asks it one time. The row's page
    /// set asks the rule for each chat; what the app gives for each tab asks it for each chat again.
    @Test func aMapWithEachPartKeptAsksThePageRuleTwoTimesForEachChat() throws {
        let session = try Session(tabs: Base.sizes[1])
        let services = session.services, tabs = session.tabs
        let ids = Set(tabs.map(\.id)), chats = tabs.count(where: { $0.agentSession != nil })
        try #require(tabs.count == Base.sizes[1] && chats == Base.sizes[1] / 3, "setup: the storm workspace has \(tabs.count) tabs and \(chats) chats")
        let counter = Counter(), ask = services.agentTabs.daemonListing
        services.agentTabs.daemonListing = { tab in
            if ids.contains(tab.id) { counter.calls += 1 }
            return ask(tab)
        }
        let title = SidebarBridge.tabTitle(services)
        /// The calls at one map with `parts` where each part is kept.
        func calls(_ parts: SidebarTabParts) throws -> Int {
            _ = session.rows(parts, title: title)
            counter.calls = 0
            let kept = session.mapped(parts, title: title)
            try #require(kept.made == 0, "setup: the second map made \(kept.made) parts, want 0")
            return counter.calls
        }
        let own = try calls(SidebarTabParts())
        let given = try calls(SidebarTabParts(given: SidebarTabParts(services).given))
        print("TAB-PARTS page rule at one map of a workspace of \(tabs.count) tabs (\(chats) chats) with each part kept: \(own - tabs.count) calls of the rule "
            + "by the row's own page set (\(own) asks of the listing daemon); \(given - tabs.count) calls with what the app gives for each tab (\(given) asks): "
            + "the rule is asked \((given - tabs.count) / max(chats, 1)) times for each chat")
        #expect(own == tabs.count + chats, "the row's own page set asked the listing daemon \(own) times, want \(tabs.count + chats): one time for each tab and one rule call for each chat")
        #expect(given - own == chats, "what the app gives for each tab asked the listing daemon \(given - own) times more, want \(chats): one rule call for each chat")
    }

    /// A report with no condition on its times: what the app gives for each tab of a workspace of 84 tabs at one
    /// map (the app's `SidebarTabParts.init(_:)`: the title where no observation covers it, and whether the favicon is of
    /// another machine's store), its two halves alone, the row's own page set beside it, and one whole map of the
    /// window's 2 rows with each part kept.
    @Test func theTimeOfWhatTheAppGivesForEachTabAtOneMap() throws {
        let session = try Session(tabs: Base.sizes[1])
        let services = session.services, tabs = session.tabs
        let workspace = try #require(session.storm, "setup: the session has no storm workspace")
        let runs = 200
        /// The mean time of one run of `body`, in milliseconds.
        func mean(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            for _ in 0 ..< runs { body() }
            let elapsed = ContinuousClock.now - start
            return (Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3) / Double(runs)
        }
        let given = try #require(SidebarTabParts(services).given, "setup: the app's tab parts give nothing for a tab")
        let titles = TabTitleResolver(services: services)
        let proxied = services.cache.pageRequests.proxiedTabs, agentTabs = services.agentTabs
        let both = mean {
            let ask = given(workspace)
            for tab in tabs { _ = ask(tab) }
        }
        let title = mean { for tab in tabs { _ = titles.unobservedTitle(tab, incognito: false) } }
        let remote = mean {
            for tab in tabs where tab.kind == .browser { _ = proxied.faviconIsRemote(key: tab.id, page: services.cache.existingBrowser(tab.id)?.tab) }
        }
        let pageSet = mean { for tab in tabs { _ = RestoredNewTabPages.shows(tab, of: workspace, in: agentTabs, restored: true) } }
        let rowTitle = SidebarBridge.tabTitle(services)
        let parts = SidebarTabParts(given: given)
        let first = session.mapped(parts, title: rowTitle)
        try #require(first.made == tabs.count + 2, "setup: the first map made \(first.made) parts, want one for each tab of the 2 workspaces")
        let map = mean { _ = session.rows(parts, title: rowTitle) }
        let chats = tabs.count(where: { $0.agentSession != nil })
        print("TAB-PARTS time of what the app gives for each tab at one map, a workspace of \(tabs.count) tabs (\(chats) chats): \(both) ms in all; "
            + "the title half alone = \(title) ms; the favicon half alone = \(remote) ms; the row's own page set = \(pageSet) ms; "
            + "one whole map of the window's 2 rows with each part kept = \(map) ms (each the mean of \(runs) runs in the tests' build; a report, no condition)")
    }

    /// A part that is kept does not hide a change that its map observed: a terminal that is not the row's front tab
    /// gets a new title, with the same input of its part, and the next map shows it and makes that one part.
    @Test func aKeptPartShowsATitleThatChangesWithTheSameInput() throws {
        let session = try Session(tabs: Base.sizes[0])
        let title = SidebarBridge.tabTitle(session.services)
        let parts = SidebarTabParts(given: SidebarTabParts(session.services).given)
        let terminal = try #require(session.tabs.last { $0.kind == .pty }, "setup: the storm workspace has no terminal")
        let first = session.mapped(parts, title: title)
        try #require(first.made == session.tabs.count + 2, "setup: the first map made \(first.made) parts, want one for each tab of the 2 workspaces")
        try #require(first.rows == session.rows(nil, title: title), "setup: the rows with kept parts are not the walk's rows")
        let kept = session.mapped(parts, title: title)
        try #require(kept.made == 0, "setup: the second map made \(kept.made) parts, want 0")

        terminal.titleText = "make check"
        let walk = session.rows(nil, title: title)
        try #require(Session.item(terminal.id, in: walk)?.title == "make check", "setup: a row made now does not show the terminal's new title")
        let next = session.mapped(parts, title: title)
        #expect(Session.item(terminal.id, in: next.rows)?.title == "make check",
                "the row shows `\(Session.item(terminal.id, in: next.rows)?.title ?? "no item")` for a terminal whose title changed to `make check`: its kept part is the old one")
        #expect(next.made == 1, "one tab's title changed and the next map made \(next.made) parts, want 1")
        #expect(next.rows == walk, "the rows with kept parts are not the walk's rows after one tab's title changed")
    }

    /// Answers each favicon with a 1x1 icon, at once.
    @MainActor final class IconLoader: BrowserFaviconLoading {
        var calls = 0

        func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
            calls += 1
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return context?.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 1, height: 1)) }
        }

        func cachedFavicon(at url: URL, profile: BrowserProfileID) -> NSImage? { nil }
    }

    /// A LIMIT, with its count: the favicon store is one observable value for each favicon that it has. One
    /// favicon that lands, of an address that no tab of the workspace shows, makes the part of EACH page of the
    /// workspace again (28 of 84 tabs), and no part of a terminal or a chat. The store is the test's own, of the
    /// app's type, with a loader that answers at once; each page of the workspace has an address of its own.
    @Test func oneFaviconThatLandsMakesThePartOfEachPageAgain() async throws {
        let session = try Session(tabs: Base.sizes[1])
        let tabs = session.tabs
        let pages = tabs.filter { $0.kind == .browser }
        try #require(pages.count == Base.sizes[1] / 3, "setup: the storm workspace has \(pages.count) pages")
        let loader = IconLoader()
        let store = TabFaviconStore(loader: loader)
        let addresses = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($1.id, "https://site-\($0).example/favicon.ico") })
        let other = "https://no-tab-shows-this.example/favicon.ico"
        let page: SidebarTabParts.Page = { _, tab in
            guard tab.kind == .browser else { return nil }
            return SidebarMapping.PageFace(favicon: store.image(for: addresses[tab.id], profile: .default).map { SidebarFavicon($0.cgImage) })
        }
        let title: SidebarBridge.TabTitle = { _, tab in tab.displayTitle }
        let parts = SidebarTabParts(page: page)

        // Each page's own favicon lands, and the rows show it.
        _ = session.mapped(parts, title: title, page: page)
        await LargeSessionFixture.drainMain()
        try #require(addresses.values.allSatisfy { store.cachedImage(for: $0, profile: .default) != nil }, "setup: the store does not have each page's favicon after the drain (\(loader.calls) fetches)")
        let shown = session.mapped(parts, title: title, page: page)
        try #require(pages.allSatisfy { Session.item($0.id, in: shown.rows)?.favicon != nil }, "setup: the rows do not show each page's favicon")
        let kept = session.mapped(parts, title: title, page: page)
        try #require(kept.made == 0, "setup: the map after each favicon landed made \(kept.made) parts, want 0")

        // One favicon that no tab shows lands.
        try #require(store.image(for: other, profile: .default) == nil, "setup: the store has the other favicon before its fetch")
        await LargeSessionFixture.drainMain()
        try #require(store.cachedImage(for: other, profile: .default) != nil, "setup: the other favicon did not land")
        let next = session.mapped(parts, title: title, page: page)
        print("TAB-PARTS one favicon that lands (an address that no tab of the workspace shows): the next map of a workspace of \(tabs.count) tabs "
            + "(\(pages.count) pages) made \(next.made) parts again")
        #expect(next.made == pages.count, "one favicon that landed made \(next.made) parts again, want \(pages.count): the part of each page (the store's favicons are one observable value), and no other part")
        #expect(next.rows == session.rows(nil, title: title, page: page), "the rows with kept parts are not the walk's rows after a favicon landed")
    }
}
