import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// SIDEBAR SMOOTH 2, F2 (SIDEBAR ROWS STATUS 15571 cause b). The window's structural rows pass walks every workspace.
/// To leave out the Home workspaces the Home item shows, it read each workspace's Home rule (`isAnyHome`: its
/// screens, each pane's first tab and that tab's page), so a change inside ONE workspace (a tab opened at the front
/// of a pane, Cmd-N's first tab replacing its stand-in) cancelled and re-ran the whole pass: 6.8 ms of
/// `generateAccessList` per Cmd-N at 200 rows (cmux21, 120 Hz). CLAUDE.md: a change's cost is O(changed items).
///
/// The pass reads the list and its order; each workspace's listing is observed apart (`SidebarRowFeed.lists`), and
/// the pass runs again only when one flips. The pass is the window's own (`SidebarBridge.passSections`) under
/// observation tracking, as `SidebarSameTurn` runs it, with a row feed whose frame the test runs by hand.
@MainActor @Suite(.serialized) struct SidebarRowsPassListOnlyTests {
    nonisolated static let count = 40
    static var keys: [String] { (0..<count).map { String(format: "k%03d", $0) } }
    /// The workspace that changes.
    static let changed = 5

    static func workspace(_ key: String, index: Int) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        let pane = PaneSnapshot(id: PaneID(rawValue: base), tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 1), kind: .pty, cwd: "/tmp/\(key)")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(PaneID(rawValue: base)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    static func tree() -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { workspace($1, index: $0) })
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    /// A daemon batch: `tab` opens at the front of workspace `index`'s pane (the pane's first tab changes).
    static func openedFirst(_ tab: TabSnapshot, in index: Int, sequence: UInt64) -> DaemonEventEnvelope {
        let base = UInt64(index + 1) * 100
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: UInt64(index + 1)), screen: ScreenID(rawValue: base), pane: PaneID(rawValue: base),
            surface: tab.surface, index: 0, entity: tab, clientTransactionID: nil)))
    }

    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        private(set) var listed: [SidebarWorkspace] = []
        /// The latest tracked pass heard a change since it ran (an older pass's registration is the app's stream's no
        /// longer: it tracks only its latest run).
        private(set) var woke = false
        private var runs = 0

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: SidebarRowsPassListOnlyTests.tree())
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"rows-pass-list","workspace_key":"rows-pass-list-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = SidebarRowsPassListOnlyTests.keys
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            #expect(services.sidebarLayout.document.hidesHome, "the default layout's Home item shows the Home workspaces")
            // The window's first pass names every row; the next one is the steady state the test measures.
            run()
            frame()
            run()
            frame()
        }

        /// The window's structural pass under observation tracking, then its rows filled outside it.
        func run() {
            woke = false
            runs += 1
            let run = runs
            let sections = withObservationTracking {
                SidebarBridge.passSections(services, window: state, feed: feed, rows: feed.rowSource).0
            } onChange: { [weak self] in
                MainActor.assumeIsolated { if self?.runs == run { self?.woke = true } }
            }
            listed = feed.fill(sections).flatMap(\.workspaces)
        }

        /// One display frame: the feed's flush.
        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }

        func lists(_ key: String) -> Bool { listed.contains { $0.id.rawValue == key } }
    }

    /// RED at base: a tab opened in one workspace woke the pass over all 40.
    @Test func aTabOpenedInOneWorkspaceRunsNoRowsPass() throws {
        let fixture = try Fixture()
        defer { fixture.feed.reset() }
        let store = fixture.services.machines.local.store
        #expect(fixture.lists(Self.keys[Self.changed]), "the fixture lists every workspace")
        _ = SidebarPerfCounters.report(reset: true)
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 9_001), kind: .pty, cwd: "/tmp/front")
        _ = store.apply(batch: [Self.openedFirst(tab, in: Self.changed, sequence: 1)])
        fixture.frame()
        let maps = SidebarPerfCounters.report(reset: true)["row_maps"] ?? 0
        print("SIDEBAR-ROWS-PASS n=\(Self.count) woke=\(fixture.woke) row_maps=\(maps)")
        #expect(!fixture.woke, "a tab opened in one workspace ran the rows pass over all \(Self.count) workspaces")
        #expect(maps <= 1, "a tab opened in one workspace mapped \(maps) rows")
    }

    /// What the listing reads still reaches the list: a workspace whose first tab becomes Home's docked page is a
    /// window's Home, which the Home item shows, so its row leaves the list on the pass that its flip runs.
    @Test func aWorkspaceThatBecomesAWindowHomeLeavesTheList() throws {
        let fixture = try Fixture()
        defer { fixture.feed.reset() }
        let store = fixture.services.machines.local.store
        let key = Self.keys[Self.changed]
        #expect(fixture.lists(key))
        var dock = TabSnapshot(surface: SurfaceID(rawValue: 9_002), kind: .conversation)
        dock.conversation = ConversationTabRef(page: WorkspaceModel.homeDockPage)
        _ = store.apply(batch: [Self.openedFirst(dock, in: Self.changed, sequence: 1)])
        #expect(store.workspace(id: key)?.isWindowHome == true, "the fixture made a window's Home")
        fixture.frame()
        #expect(fixture.woke, "the listing flipped: the pass runs again")
        fixture.run()
        #expect(!fixture.lists(key), "a window's Home is not a workspace row while the Home item shows it")
        #expect(fixture.listed.count == Self.count - 1)
    }
}
