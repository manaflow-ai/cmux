import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextHomeModel
@testable import CmuxNextSidebar
import Foundation
import Testing

/// ONE TAB THAT CHANGES MAKES ONLY ITS OWN PART AGAIN.
///
/// Three maps of the app make one item for each workspace and keep it by workspace: the sidebar's row
/// (`SidebarRowFeed`), the New Tab bar's kept rows (`NewTabPlacesKept`) and the home view's agents
/// (`HomeAgentGlances.feed(while:)`). A change in one workspace maps that workspace only (`SidebarRowFanOutTests`,
/// `NewTabPlacesKeptCostTests`). But the map of that one workspace makes a part for EACH of its tabs: a tab closed or
/// made in a workspace of 84 tabs makes 83 or 85 parts, where only one tab changed. A key that is held makes tab
/// after tab in one workspace, so each key pays for each tab that the hold made.
///
/// The rows are counts in one turn, with no time. Each row makes ONE tab and then closes ONE tab in a workspace of
/// 6 tabs and in a workspace of 84 tabs (a terminal, then a page, in turn; the tab that comes and goes is a
/// terminal), and wants the same count of parts at both sizes: the new tab's own part, and no part for a tab that
/// closed.
///
/// - The sidebar's row: the count is of the calls of the two functions that the row asks for each tab, which the
///   test gives (`tabTitle`: the tab list's title of a tab; `pageFace`: a page's face). `rows_made` is the sidebar's
///   own counter.
/// - The New Tab bar's rows and the home view's agents: the count is the module's own work counter
///   (``ObservationWork``), set around the start of each feed.
///
/// After each change the kept rows and the kept agents are those of a walk over every workspace, made then.
///
/// Limits: no window and no view; the sidebar's row is mapped by the app's own mapping with the test's two
/// functions, not with the app's page face.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct TabPartsKeptTests {
    /// The workspace whose tabs change.
    nonisolated static let storm = "k000"
    /// The two sizes of that workspace.
    nonisolated static let sizes = [6, 84]

    static func keys(_ count: Int) -> [String] { (0..<count).map { String(format: "k%03d", $0) } }

    /// Workspace `key` with `count` tabs in one pane: a terminal, then a page, in turn. With `chats`, each third
    /// tab is an agent chat.
    static func workspace(_ key: String, index: Int, tabs count: Int, chats: Bool) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 1000
        let tabs = (0..<count).map { at -> TabSnapshot in
            let surface = SurfaceID(rawValue: base + 1 + UInt64(at))
            if chats, at % 3 == 2 {
                var chat = TabSnapshot(surface: surface, kind: .conversation, cwd: nil)
                chat.title = "chat \(key).\(at)"
                chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:tab-parts", session: "s-\(key)-\(at)", harness: nil))
                return chat
            }
            guard at % 2 == 1 else { return TabSnapshot(surface: surface, kind: .pty, cwd: "/tmp/\(key)") }
            var page = TabSnapshot(surface: surface, kind: .browser, cwd: nil)
            page.url = "https://example.com/\(key)/\(at)"
            page.title = "Page \(key).\(at)"
            return page
        }
        let pane = PaneSnapshot(id: PaneID(rawValue: base), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(PaneID(rawValue: base)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    /// The session's tree: `keys` in order, each with 2 tabs, the storm workspace with `tabs`. `registry`: the home
    /// session's id, with each workspace in its personal order (an app's store); nil for a store with no app.
    static func tree(_ keys: [String], storm tabs: Int, chats: Bool = false, registry: String? = "s-local") -> DaemonTree {
        var tree = DaemonTree(registryID: registry, workspaces: keys.enumerated().map { index, key in
            workspace(key, index: index, tabs: key == storm ? tabs : 2, chats: key == storm && chats)
        })
        guard let registry else { return tree }
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: registry, workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    /// An app with the session in its local store, connected.
    static func app(_ keys: [String], storm tabs: Int, chats: Bool = false) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(keys, storm: tabs, chats: chats))
        return services
    }

    /// What one change cost the sidebar's row.
    struct RowCost {
        /// Calls of `tabTitle`: the tabs whose title in the tab list the row made.
        var titles = 0
        /// Calls of `pageFace` for the workspace's first tab (the tab that names the row).
        var faceCalls = 0
        /// Calls of `pageFace` for each other tab.
        var otherFaces = 0
        /// `rows_made`: the rows mapped from their stores.
        var rowsMade = 0
    }

    /// One window's rows over the session through a row feed whose frames run only in `frame()`, as
    /// `SidebarRowFanOutTests` has them, with the two functions that the row asks for each tab counted.
    @MainActor final class Rows {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        let keys: [String]
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        final class Calls {
            var titles: [String] = []
            var faces: [String] = []
        }
        let calls = Calls()
        /// The rows the last pass listed.
        private(set) var listed = 0

        init(session: Int, tabs: Int) throws {
            let keys = TabPartsKeptTests.keys(session)
            let services = try TabPartsKeptTests.app(keys, storm: tabs)
            (self.keys, self.services) = (keys, services)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"tab-parts","workspace_key":"tab-parts-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = keys
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            pass()
            frame()
        }

        /// The structural pass, as the window's sidebar runs it: every listed row named, new rows mapped and observed.
        func pass() {
            feed.beginPass(inputs: 0)
            let sections = SidebarBridge.sections(services.machines, doc: services.sidebarDoc, members: keys, profile: state.profileID,
                                                  pageFace: { [calls] _, tab, _ in
                                                      calls.faces.append(tab.id)
                                                      return nil
                                                  },
                                                  tabTitle: { [calls] _, tab in
                                                      calls.titles.append(tab.id)
                                                      return tab.displayTitle
                                                  },
                                                  rows: feed.rowSource)
            listed = feed.fill(sections).flatMap(\.workspaces).count
        }

        /// One display frame: the row feed's flush maps its dirty rows again and arms them.
        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }

        /// What the row's map cost after the storm workspace got `tabs` tabs: the change, then the pass and the frame
        /// that follow it. `first`: the id of that workspace's first tab.
        func cost(storm tabs: Int, first: String) -> RowCost {
            _ = SidebarPerfCounters.report(reset: true)
            calls.titles.removeAll()
            calls.faces.removeAll()
            services.machines.local.store.apply(snapshot: TabPartsKeptTests.tree(keys, storm: tabs))
            pass()
            frame()
            let report = SidebarPerfCounters.report(reset: true)
            return RowCost(titles: calls.titles.count, faceCalls: calls.faces.filter { $0 == first }.count,
                           otherFaces: calls.faces.filter { $0 != first }.count, rowsMade: report["rows_made"] ?? 0)
        }
    }

    /// The id of the first tab of the storm workspace (the only workspace with more than 2 tabs).
    static func firstStormTab(_ store: DaemonStore) -> String? {
        store.workspaces.first(where: { $0.screens.flatMap(\.panes).flatMap(\.tabs).count > 2 })?.screens.first?.panes.first?.tabs.first?.id
    }

    /// The sidebar's row, in a session of 40 workspaces and of 200.
    @Test(arguments: [40, 200])
    func aTabMadeOrClosedMakesNoOtherTabsPartOfItsSidebarRow(session: Int) throws {
        let fixture = try Rows(session: session, tabs: Self.sizes[0])
        defer { fixture.feed.reset() }
        try #require(fixture.listed == session, "setup: the fixture lists \(fixture.listed) of \(session) workspaces")
        let first = try #require(Self.firstStormTab(fixture.services.machines.local.store), "setup: the storm workspace has no tab")
        var costs: [(made: RowCost, closed: RowCost)] = []
        for tabs in Self.sizes {
            // The workspace at this size; its cost is no row.
            _ = fixture.cost(storm: tabs, first: first)
            let made = fixture.cost(storm: tabs + 1, first: first)
            let closed = fixture.cost(storm: tabs, first: first)
            costs.append((made, closed))
        }
        let (small, large) = (costs[0], costs[1])
        print("TAB-PARTS sidebar row, session of \(session) workspaces: a workspace of \(Self.sizes[0]) tabs: one tab made = \(small.made), "
            + "one tab closed = \(small.closed); a workspace of \(Self.sizes[1]) tabs: one tab made = \(large.made), one tab closed = \(large.closed)")
        for (name, cost) in [("made", small.made), ("closed", small.closed), ("made", large.made), ("closed", large.closed)] {
            try #require(cost.faceCalls >= 1, "setup: the row's map after one tab \(name) asked no page face for the workspace's first tab (it is not the tab that names the row)")
            #expect(cost.rowsMade == 1, "one tab \(name) in one workspace mapped \(cost.rowsMade) rows of \(session), want 1")
        }
        #expect(small.made.titles == large.made.titles,
                "one tab made: the row made the tab list's title of \(small.made.titles) tabs in a workspace of \(Self.sizes[0]) tabs and of \(large.made.titles) in one of \(Self.sizes[1]), want the same count")
        #expect(small.closed.titles == large.closed.titles,
                "one tab closed: the row made the tab list's title of \(small.closed.titles) tabs in a workspace of \(Self.sizes[0]) tabs and of \(large.closed.titles) in one of \(Self.sizes[1]), want the same count")
        #expect(large.made.titles <= 1 && large.closed.titles == 0,
                "the row made the tab list's title of \(large.made.titles) tabs for one tab made and of \(large.closed.titles) for one tab closed, want the new tab's own and none")
        let others = [small.made.otherFaces, small.closed.otherFaces, large.made.otherFaces, large.closed.otherFaces]
        #expect(others == [0, 0, 0, 0],
                "the row asked a page face for \(others) tabs that are not its first tab (one tab made and closed at \(Self.sizes[0]) tabs, then at \(Self.sizes[1])), want 0: no page changed")
    }

    @MainActor final class Events {
        var count = 0
    }

    /// The New Tab bar's kept rows, with a store only.
    @Test func aTabMadeOrClosedMakesNoOtherTabsPartOfItsNewTabRows() async throws {
        let keys = Self.keys(40)
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "tab-parts"), generationChanged: true))
        store.apply(snapshot: Self.tree(keys, storm: Self.sizes[0], registry: nil))
        let kept = NewTabPlacesKept(home: "/Users/you")
        let events = Events()
        let work = ObservationWork()
        ObservationWork.$current.withValue(work) {
            kept.follow(list: { [store] in store.workspaces },
                        rows: { [weak kept] workspace in kept?.mapped(workspace, machine: nil) },
                        changed: { events.count += 1 })
        }
        await LargeSessionFixture.drainMain()
        await LargeSessionFixture.drainMain()
        let first = kept.rows?.count ?? -1
        try #require(first == keys.count, "setup: the holder kept the rows of \(first) workspaces after the drain, want \(keys.count)")

        let places = NewTabPlaces(home: "/Users/you")
        /// Every workspace's rows, made now with no kept part: what the kept rows must be.
        func walk() -> [NewTabPlaces.Rows] { store.workspaces.map { places.rows(NewTabPlaces.Source($0), machine: nil) } }
        /// Gives the storm workspace `tabs` tabs, lets the main actor run, and gives the tab parts that the holder's
        /// work made for it and whether the kept rows are the walk's.
        func step(_ tabs: Int) async -> (parts: Int, same: Bool) {
            work.reset()
            let before = events.count
            store.apply(snapshot: Self.tree(keys, storm: tabs, registry: nil))
            await LargeSessionFixture.drainMain()
            await LargeSessionFixture.drainMain()
            #expect(events.count > before || tabs == Self.sizes[0], "setup: the holder's `changed` did not run after the workspace got \(tabs) tabs")
            return (work.byStep["NewTabPlaces.tabParts"] ?? 0, kept.rows == walk())
        }

        var costs: [(made: Int, closed: Int)] = []
        for tabs in Self.sizes {
            // The workspace at this size; its cost is no row.
            let sized = await step(tabs)
            let made = await step(tabs + 1)
            let closed = await step(tabs)
            #expect(sized.same && made.same && closed.same, "the kept rows are not the walk's rows at \(tabs) tabs (sized \(sized.same), made \(made.same), closed \(closed.same))")
            costs.append((made.parts, closed.parts))
        }
        let (small, large) = (costs[0], costs[1])
        print("TAB-PARTS new tab rows: a workspace of \(Self.sizes[0]) tabs: one tab made = \(small.made) parts, one tab closed = \(small.closed) parts; "
            + "a workspace of \(Self.sizes[1]) tabs: one tab made = \(large.made) parts, one tab closed = \(large.closed) parts")
        #expect(small.made == large.made, "one tab made: \(small.made) tab parts in a workspace of \(Self.sizes[0]) tabs and \(large.made) in one of \(Self.sizes[1]), want the same count")
        #expect(small.closed == large.closed, "one tab closed: \(small.closed) tab parts in a workspace of \(Self.sizes[0]) tabs and \(large.closed) in one of \(Self.sizes[1]), want the same count")
        #expect(large.made <= 1 && large.closed == 0, "\(large.made) tab parts for one tab made and \(large.closed) for one tab closed, want the new tab's own and none")
    }

    /// The home view's agents, with the app's own feed.
    @Test func aTabMadeOrClosedMakesNoOtherTabsPartOfItsAgentGlances() async throws {
        let keys = Self.keys(40)
        let services = try Self.app(keys, storm: Self.sizes[0], chats: true)
        let store = services.machines.local.store
        let glances = HomeAgentGlances(services: services)
        let feed = glances.feed(while: { true })
        let work = ObservationWork()
        ObservationWork.$current.withValue(work) { feed.start() }
        defer { feed.stop() }
        await LargeSessionFixture.drainMain()
        await LargeSessionFixture.drainMain()
        let first = feed.observedItems?.count ?? -1
        try #require(first == keys.count, "setup: the feed has the agents of \(first) workspaces after the drain, want \(keys.count)")

        /// Every workspace's agents, made now with no kept part: what the feed's items must be.
        func walk() -> [[HomeAgentGlance]] { services.machines.allWorkspaces.map { glances.glances(in: $0.0) } }
        /// Gives the storm workspace `tabs` tabs, lets the main actor run, and gives the tab parts that the feed's
        /// work made for it and whether the feed's items are the walk's.
        func step(_ tabs: Int) async -> (parts: Int, same: Bool) {
            work.reset()
            store.apply(snapshot: Self.tree(keys, storm: tabs, chats: true))
            await LargeSessionFixture.drainMain()
            await LargeSessionFixture.drainMain()
            return (work.byStep["HomeAgentGlances.tabParts"] ?? 0, feed.observedItems == walk())
        }

        var costs: [(made: Int, closed: Int)] = []
        for tabs in Self.sizes {
            // The workspace at this size; its cost is no row.
            let sized = await step(tabs)
            let made = await step(tabs + 1)
            let closed = await step(tabs)
            #expect(sized.same && made.same && closed.same, "the feed's agents are not the walk's agents at \(tabs) tabs (sized \(sized.same), made \(made.same), closed \(closed.same))")
            costs.append((made.parts, closed.parts))
        }
        let (small, large) = (costs[0], costs[1])
        let agents = feed.observedItems?.map(\.count).reduce(0, +) ?? -1
        print("TAB-PARTS agent glances (\(agents) agents in the feed): a workspace of \(Self.sizes[0]) tabs: one tab made = \(small.made) parts, one tab closed = \(small.closed) parts; "
            + "a workspace of \(Self.sizes[1]) tabs: one tab made = \(large.made) parts, one tab closed = \(large.closed) parts")
        #expect(small.made == large.made, "one tab made: \(small.made) tab parts in a workspace of \(Self.sizes[0]) tabs and \(large.made) in one of \(Self.sizes[1]), want the same count")
        #expect(small.closed == large.closed, "one tab closed: \(small.closed) tab parts in a workspace of \(Self.sizes[0]) tabs and \(large.closed) in one of \(Self.sizes[1]), want the same count")
        #expect(large.made <= 1 && large.closed == 0, "\(large.made) tab parts for one tab made and \(large.closed) for one tab closed, want the new tab's own and none")
    }
}
