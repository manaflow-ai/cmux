import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// Leo 2026-10-21 (sidebar organization, item A): a working row's second line says what its agent
/// does right now ("Now: Running the test suite"), from the acpmux lane's masked step. A one-line
/// row stays one line, so rows never grow and shrink as agents start and stop.
@MainActor @Suite(.serialized) struct SidebarNowLineTests {
    typealias Lanes = SidebarLaneStatusTests

    @MainActor struct Fixture {
        let store = DaemonStore()
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()

        init() throws {
            store.apply(snapshot: DaemonTree(workspaces: [
                Lanes.workspace(1, "working", session: "s-working", harness: "claude"),
                Lanes.workspace(2, "idle", session: "s-idle", harness: "codex"),
            ]))
            turns.localHost = Lanes.host
            for (name, state, step) in [("working", "working", "Running the test suite"), ("idle", "idle", "Opened the pull request")] {
                lanes.lanes["s-\(name)"] = try #require(AgentActivityLane.of(summary: [
                    "sessionId": "s-\(name)", "name": name, "lane": ["state": state, "step": step],
                ]))
            }
        }

        func rows() -> [String: SidebarWorkspace] {
            let sections = SidebarMapping.shared.sections(
                store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                rowSource: SidebarLaneStatus.applying(nil, lanes: lanes, turns: turns, marks: AgentPriorityMarks(defaults: nil)))
            return Dictionary(uniqueKeysWithValues: sections.flatMap(\.workspaces).map { ($0.title, $0) })
        }
    }

    /// Runs `body` with `sidebar.nowLine` at `on` (nil: its default), then clears it.
    static func withNowLine(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.nowLine.key
        TunableStore.shared.set(key, on.map { .bool($0) })
        defer { TunableStore.shared.set(key, nil) }
        try body()
    }

    /// Off by default since Lawrence 2026-10-21 (minimal rows).
    @Test func offByDefault() throws {
        let fixture = try Fixture()
        Self.withNowLine(nil) { #expect(fixture.rows().values.allSatisfy { $0.agentStep == nil }) }
    }

    @Test func aWorkingRowKnowsWhatItsAgentDoesWhenOn() throws {
        let fixture = try Fixture()
        try Self.withNowLine(true) {
            let rows = fixture.rows()
            #expect(rows["working"]?.agentStep == "Running the test suite")
            #expect(rows["idle"]?.agentStep == nil, "an idle chat's last step is not what it does now")
        }
    }

    @Test func aRowWithASecondLineSaysItThere() throws {
        let fixture = try Fixture()
        try Self.withNowLine(true) {
            var working = try #require(fixture.rows()["working"])
            working.lastMessage = "Earlier reply"
            var options = SidebarLayoutOptions()
            options.expanded = true
            let content = options.rowContent(working, machine: nil)
            #expect(content.now == "Running the test suite")
            #expect(content.detail == "Running the test suite")
        }
    }

    @Test func aOneLineRowStaysOneLine() throws {
        let fixture = try Fixture()
        try Self.withNowLine(true) {
            let content = SidebarLayoutOptions().rowContent(try #require(fixture.rows()["working"]), machine: nil)
            #expect(content.now == nil)
            #expect(content.detail == nil)
        }
    }

    @Test func aStepOfSeveralLinesShowsItsFirst() throws {
        let lane = try #require(AgentActivityLane.of(summary: [
            "sessionId": "s", "name": "s", "lane": ["state": "working", "step": "  Running tests\nsecond line"],
        ]))
        #expect(SidebarLaneStatus.step([lane]) == "Running tests")
    }

    @Test func toggleOffSaysNothing() throws {
        let fixture = try Fixture()
        Self.withNowLine(false) {
            #expect(fixture.rows().values.allSatisfy { $0.agentStep == nil })
        }
    }
}
