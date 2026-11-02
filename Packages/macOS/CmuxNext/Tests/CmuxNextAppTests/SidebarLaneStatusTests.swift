import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextSidebar
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// Leo 2026-10-15: each agent session's sidebar row shows its live status (working, waiting on
/// you, failed, idle) from the acpmux lane `_acpmux/watch` reports (`AgentLaneStore`), whatever
/// harness runs the chat, behind the Debug toggle `sidebar.laneStatus`.
@MainActor @Suite(.serialized) struct SidebarLaneStatusTests {
    static let host = "install:lane-status"

    /// A workspace whose one tab is an agent chat of `session` on this Mac.
    static func workspace(_ id: UInt64, _ name: String, session: String, harness: String) -> WorkspaceSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: harness))
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [tab])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: name, screens: [screen])
    }

    /// A stale local agent tab can share a workspace with a live terminal tab.
    static func workspaceWithTerminal(_ id: UInt64, _ name: String, session: String, harness: String) -> WorkspaceSnapshot {
        var workspace = workspace(id, name, session: session, harness: harness)
        workspace.screens[0].panes[0].tabs.append(TabSnapshot(surface: SurfaceID(rawValue: id + 100), kind: .pty))
        return workspace
    }

    /// One `_acpmux/watch` session summary's lane.
    static func lane(_ session: String, _ state: String) throws -> AgentActivityLane {
        try #require(AgentActivityLane.of(summary: ["sessionId": session, "name": session, "lane": ["state": state]]))
    }

    /// Four chats of four harnesses, one per lane state, and nothing in the turn store.
    @MainActor struct Fixture {
        let store = DaemonStore()
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()

        init() throws {
            store.apply(snapshot: DaemonTree(workspaces: [
                SidebarLaneStatusTests.workspace(1, "working", session: "s-working", harness: "claude"),
                SidebarLaneStatusTests.workspace(2, "waiting", session: "s-waiting", harness: "codex"),
                SidebarLaneStatusTests.workspace(3, "failed", session: "s-failed", harness: "opencode"),
                SidebarLaneStatusTests.workspace(4, "idle", session: "s-idle", harness: "gemini"),
            ]))
            turns.localHost = SidebarLaneStatusTests.host
            for (session, state) in [("s-working", "working"), ("s-waiting", "input"), ("s-failed", "failed"), ("s-idle", "idle")] {
                lanes.lanes[session] = try SidebarLaneStatusTests.lane(session, state)
            }
        }

        func sections(_ rows: SidebarMapping.RowSource? = nil,
                      workspaceFilter: (WorkspaceModel) -> Bool = { _ in true }) -> [SidebarRowSection] {
            SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                           rowSource: SidebarLaneStatus.applying(rows, lanes: lanes, turns: turns),
                                           workspaceFilter: workspaceFilter)
        }
    }

    static func activity(_ sections: [SidebarRowSection]) -> [String: StatusIndicatorState] {
        Dictionary(uniqueKeysWithValues: sections.flatMap(\.workspaces).map { ($0.title, $0.activity) })
    }

    /// Runs `body` with `sidebar.laneStatus` set to `on`, then clears it. Active without a file: nothing is written.
    static func withLaneStatus(_ on: Bool, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.laneStatus.key
        TunableStore.shared.set(key, .bool(on))
        defer { TunableStore.shared.set(key, nil) }
        try body()
    }

    @Test func eachRowShowsItsLanesState() throws {
        let fixture = try Fixture()
        try Self.withLaneStatus(true) {
            let model = SidebarModel(sections: [])
            SidebarRows(model: model, document: { nil }).show(fixture.sections())
            let shown = Self.activity(model.sections)
            #expect(shown["working"] == .working)
            #expect(shown["waiting"] == .waiting)
            #expect(shown["failed"] == .error)
            #expect(shown["idle"] == .idle)
        }
    }

    @Test func toggleOffLeavesRowsAsTheyWere() throws {
        let fixture = try Fixture()
        Self.withLaneStatus(false) {
            let shown = Self.activity(fixture.sections())
            #expect(shown.count == 4)
            #expect(shown.values.allSatisfy { $0 == .idle }, "no turn state reached the rows, and lanes are not read")
        }
    }

    @Test func aLaneChangeMapsItsRowAgain() throws {
        let fixture = try Fixture()
        try Self.withLaneStatus(true) {
            final class Pending { var work: [@MainActor @Sendable () -> Void] = [] }
            let pending = Pending()
            let feed = SidebarRowFeed(schedule: { pending.work.append($0) })
            let model = SidebarModel(sections: [])
            let rows = SidebarRows(model: model, document: { nil })
            feed.onChange = { rows.patch($0) }
            feed.beginPass(inputs: 0)
            rows.show(feed.fill(fixture.sections(feed.rowSource)))
            #expect(Self.activity(model.sections)["idle"] == .idle)

            fixture.lanes.lanes["s-idle"] = try Self.lane("s-idle", "failed")
            #expect(!pending.work.isEmpty, "the lane change marks the row that read it")
            pending.work.forEach { $0() }
            #expect(Self.activity(model.sections)["idle"] == .error)
            #expect(Self.activity(model.sections)["working"] == .working)
        }
    }

    @Test func aPurgedSessionStopsKeepingItsWorkspaceRow() throws {
        let fixture = try Fixture()
        fixture.lanes.live = true
        let filter: (WorkspaceModel) -> Bool = { fixture.lanes.keepsWorkspace($0, turns: fixture.turns) }
        #expect(Self.activity(fixture.sections(workspaceFilter: filter)).count == 4)

        fixture.lanes.lanes["s-idle"] = nil
        let shown = Self.activity(fixture.sections(workspaceFilter: filter))
        #expect(shown["idle"] == nil, "a purged acpmux session does not linger as a row")
        #expect(shown.count == 3)
    }

    @Test func aStaleAgentTabDoesNotDropAWorkspaceWithOtherContent() throws {
        let fixture = try Fixture()
        fixture.lanes.live = true
        let mixed = Self.workspaceWithTerminal(5, "mixed", session: "s-mixed", harness: "codex")
        fixture.store.apply(snapshot: DaemonTree(workspaces: [mixed]))
        let workspace = try #require(fixture.store.workspaces.first)
        fixture.lanes.lanes["s-mixed"] = nil
        #expect(fixture.lanes.keepsWorkspace(workspace, turns: fixture.turns))

        var unbound = Self.workspace(6, "unbound", session: "s-unused", harness: "codex")
        unbound.screens[0].panes[0].tabs[0].conversation = ConversationTabRef(
            agentSession: AgentSessionRef(host: Self.host, session: nil, harness: "codex"))
        fixture.store.apply(snapshot: DaemonTree(workspaces: [unbound]))
        let unboundWorkspace = try #require(fixture.store.workspaces.first)
        #expect(fixture.lanes.keepsWorkspace(unboundWorkspace, turns: fixture.turns))
    }
}
