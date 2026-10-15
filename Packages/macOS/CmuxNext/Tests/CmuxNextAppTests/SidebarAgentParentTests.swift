import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// Group by Status's elbow children read who started whom from acpmux: a session a coordinator
/// started carries the coordinator's name in its `mux.parent` tag (`_acpmux/watch`), and the
/// sidebar row of the workspace showing that session names the coordinator's workspace as its
/// parent, whatever harness runs either chat.
@MainActor
struct SidebarAgentParentTests {
    static let host = "install:elbow"

    /// A workspace whose one tab is an agent chat of `session` on this Mac.
    static func workspace(_ id: UInt64, _ name: String, session: String, harness: String) -> WorkspaceSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: harness))
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [tab])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: name, screens: [screen])
    }

    /// One `_acpmux/watch` session summary with its lane, tagged with its coordinator when given.
    static func lane(_ session: String, name: String, parent: String? = nil) -> AgentActivityLane? {
        var summary: [String: Any] = ["sessionId": session, "name": name, "lane": ["state": "working"]]
        if let parent { summary["tags"] = [AgentActivityLane.parentTag: parent] }
        return AgentActivityLane.of(summary: summary, title: nil)
    }

    @Test func aStartedSessionsRowNamesItsCoordinatorsWorkspace() throws {
        defer { SidebarStatusGroupingTests.resetToggles() }
        SidebarStatusGroupingTests.toggles(status: true, elbows: true)
        let rows = Self.mappedRows()
        let coordinator = try #require(rows.first { $0.title == "coordinator" })
        let worker = try #require(rows.first { $0.title == "worker" })
        let loner = try #require(rows.first { $0.title == "loner" })
        #expect(worker.parentWorkspace == coordinator.id, "the worker's mux.parent names the coordinator's session")
        #expect(coordinator.parentWorkspace == nil)
        #expect(loner.parentWorkspace == nil)
    }

    /// Review of #20905: with the elbow off, no row reads a lane, so no row is linked (and a lane
    /// change maps no row again).
    @Test func withTheElbowOffNoRowIsLinked() throws {
        defer { SidebarStatusGroupingTests.resetToggles() }
        SidebarStatusGroupingTests.toggles(status: true, elbows: false)
        let rows = Self.mappedRows()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.agentLink == nil && $0.parentWorkspace == nil }, "\(rows.map(\.title))")
    }

    /// The three workspaces mapped and shown as the window's sidebar shows them.
    static func mappedRows() -> [SidebarWorkspace] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            Self.workspace(1, "coordinator", session: "s-coord", harness: "claude"),
            Self.workspace(2, "worker", session: "s-worker", harness: "codex"),
            Self.workspace(3, "loner", session: "s-loner", harness: "opencode"),
        ]))
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let lanes = AgentLaneStore()
        for lane in [Self.lane("s-coord", name: "lead"), Self.lane("s-worker", name: "lead-w1", parent: "lead"),
                     Self.lane("s-loner", name: "solo")].compactMap({ $0 }) {
            lanes.lanes[lane.id] = lane
        }
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                                      rowSource: SidebarMapping.linkingAgents(nil, lanes: lanes, turns: turns))
        let model = SidebarModel(sections: [])
        SidebarRows(model: model).show(sections)
        return model.sections.flatMap(\.workspaces)
    }
}
