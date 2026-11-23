import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// David Beyer, Nov 20 call: a task list that tracks what is done and what is next across a long
/// agent chat, shown per chat in the sidebar. acpmux keeps the chat's `taskList` across its turns;
/// the chat's row shows a quiet "1/3" while steps are left, and its hover card says Now and Next.
@MainActor @Suite(.serialized) struct SidebarTaskProgressTests {
    typealias Lanes = SidebarLaneStatusTests

    static func list(_ done: Int, _ total: Int, current: String? = nil, next: String? = nil,
                     at ms: Double = 1_000) -> [String: Any] {
        var list: [String: Any] = ["source": "harness", "done": done, "total": total, "updatedAt": ms]
        list["current"] = current
        list["next"] = next
        return list
    }

    static func lane(_ session: String, _ state: String, _ taskList: [String: Any]?) throws -> AgentActivityLane {
        var summary: [String: Any] = ["sessionId": session, "name": session, "lane": ["state": state]]
        summary["taskList"] = taskList
        return try #require(AgentActivityLane.of(summary: summary))
    }

    @MainActor struct Fixture {
        let store = DaemonStore()
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()

        init() throws {
            store.apply(snapshot: DaemonTree(workspaces: [
                Lanes.workspace(1, "planned", session: "s-planned", harness: "claude"),
                Lanes.workspace(2, "finished", session: "s-finished", harness: "codex"),
            ]))
            turns.localHost = Lanes.host
            lanes.lanes["s-planned"] = try SidebarTaskProgressTests.lane(
                "s-planned", "idle", SidebarTaskProgressTests.list(1, 3, current: "Fix the queue", next: "Land"))
            lanes.lanes["s-finished"] = try SidebarTaskProgressTests.lane(
                "s-finished", "idle", SidebarTaskProgressTests.list(2, 2))
        }

        func rows() -> [String: SidebarWorkspace] {
            let sections = SidebarMapping.shared.sections(
                store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                rowSource: SidebarLaneStatus.applying(nil, lanes: lanes, turns: turns, marks: AgentPriorityMarks(defaults: nil)))
            return Dictionary(uniqueKeysWithValues: sections.flatMap(\.workspaces).map { ($0.title, $0) })
        }
    }

    /// Runs `body` with `sidebar.taskProgress` at `on` (nil: its default), then clears it.
    static func withTaskProgress(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.taskProgress.key
        TunableStore.shared.set(key, on.map { .bool($0) })
        defer { TunableStore.shared.set(key, nil) }
        try body()
    }

    @Test func theSummaryListIsReadAndAnEmptyOneIsNone() {
        let list = AgentTaskList.of(Self.list(1, 3, current: "Fix", next: "Land", at: 2_000))
        #expect(list == AgentTaskList(source: .harness, done: 1, total: 3, current: "Fix", next: "Land",
                                      updatedAt: Date(timeIntervalSince1970: 2)))
        #expect(AgentTaskList.of(Self.list(0, 0)) == nil)
        #expect(AgentTaskList.of(nil) == nil)
        #expect(AgentTaskList.of("3/7") == nil)
        #expect(AgentTaskList.of(["total": 2, "source": "chief", "done": 9])?.done == 2)
    }

    @Test func aWorkingChatsListLeadsElseTheNewest() throws {
        let older = try Self.lane("a", "working", Self.list(1, 4, at: 1_000))
        let newer = try Self.lane("b", "idle", Self.list(2, 5, at: 9_000))
        let done = try Self.lane("c", "working", Self.list(3, 3, at: 9_999))
        #expect(SidebarLaneStatus.taskProgress([newer, older, done]) == SidebarTaskProgress(done: 1, total: 4))
        let idle = try Self.lane("a", "idle", Self.list(1, 4, at: 1_000))
        #expect(SidebarLaneStatus.taskProgress([idle, newer]) == SidebarTaskProgress(done: 2, total: 5))
        #expect(SidebarLaneStatus.taskProgress([done]) == nil, "a finished list says nothing a row needs")
    }

    @Test func aRowWithStepsLeftShowsItsCountQuietly() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            let rows = fixture.rows()
            let planned = try #require(rows["planned"])
            #expect(planned.taskProgress == SidebarTaskProgress(done: 1, total: 3, current: "Fix the queue", next: "Land"))
            #expect(rows["finished"]?.taskProgress == nil)
            let content = SidebarLayoutOptions().rowContent(planned, machine: nil)
            #expect(content.trailingStatus == "1/3")
            #expect(content.tasks?.total == 3)
            #expect(content.detail == nil, "a one-line row stays one line")
        }
    }

    @Test func theCountNeverCoversAnExpandedRowsAge() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            var planned = try #require(fixture.rows()["planned"])
            planned.lastActivity = Date(timeIntervalSince1970: 1_000)
            var options = SidebarLayoutOptions()
            options.expanded = true
            // Timestamps are off by default: the expanded row has no age, so the count may sit there.
            #expect(options.rowContent(planned, machine: nil).trailingStatus == "1/3")
            options.showsTimestamps = true
            let content = options.rowContent(planned, machine: nil)
            #expect(content.time != nil)
            #expect(content.trailingStatus == nil)
        }
    }

    @Test func theHoverCardSaysHowFarNowAndNext() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            let planned = try #require(fixture.rows()["planned"])
            let card = WorkspaceHoverCardContent.make(planned, machine: nil, now: Date())
            let facts = Dictionary(card.facts.map { ($0.kind, $0.text) }, uniquingKeysWith: { first, _ in first })
            #expect(facts["tasks"] == "1 of 3 tasks done")
            #expect(facts["taskNow"] == "Now: Fix the queue")
            #expect(facts["taskNext"] == "Next: Land")
        }
    }

    @Test func theTunableTurnsItOff() throws {
        let fixture = try Fixture()
        Self.withTaskProgress(false) {
            #expect(fixture.rows().values.allSatisfy { $0.taskProgress == nil })
        }
    }
}
