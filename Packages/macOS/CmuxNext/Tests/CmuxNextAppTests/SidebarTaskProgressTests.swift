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
/// the chat's row shows it as `SidebarTaskProgressLook.shipped` draws it (Leo 2026-11-22: never a count on the name's
/// line, which cut a title to "limit 0/1"), and its hover card says Now and Next.
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

    @Test func nothingEverSitsOnTheNamesLine() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            let rows = fixture.rows()
            var planned = try #require(rows["planned"])
            #expect(planned.taskProgress == SidebarTaskProgress(done: 1, total: 3, current: "Fix the queue", next: "Land"))
            #expect(rows["finished"]?.taskProgress == nil)
            for look in SidebarTaskProgressLook.allCases {
                for working in [false, true] {
                    planned.agentWorking = working
                    var options = SidebarLayoutOptions()
                    options.taskProgressLook = look
                    let content = options.rowContent(planned, machine: nil)
                    #expect(content.trailingStatus == nil, "\(look): \(content.trailingStatus ?? "")")
                    #expect(content.detail == nil && content.taskStep == nil, "\(look): a one-line row stays one line")
                }
            }
        }
    }

    @Test func theShippedLookDrawsNoHairline() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            var planned = try #require(fixture.rows()["planned"])
            planned.agentWorking = true
            #expect(SidebarTaskProgressLook.shipped == .stepLine)
            #expect(SidebarLayoutOptions().rowContent(planned, machine: nil).taskBar == nil,
                    "the gallery's hairlines read as underlines; the shipped look is the step line alone")
        }
    }

    @Test func aWorkingRowDrawsTheHairlineOnlyForTwoStepsOrMore() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            var planned = try #require(fixture.rows()["planned"])
            var options = SidebarLayoutOptions()
            options.taskProgressLook = .segments
            #expect(options.rowContent(planned, machine: nil).taskBar == nil, "an idle chat's list draws no hairline")
            planned.agentWorking = true
            let content = options.rowContent(planned, machine: nil)
            #expect(content.taskBar == SidebarTaskBar(style: .segments, progress: planned.taskProgress!))
            #expect(content.tasks?.total == 3)
            planned.taskProgress = SidebarTaskProgress(done: 0, total: 1, current: "Cap the queue")
            #expect(options.rowContent(planned, machine: nil).taskBar == nil, "a one-step list draws no hairline")
            planned.taskProgress = SidebarTaskProgress(done: 1, total: 3)
            planned.progress = SidebarProgress(value: 0.5)
            #expect(options.rowContent(planned, machine: nil).taskBar == nil, "a reported progress bar keeps the row's foot")
        }
    }

    @Test func aTwoLineRowReadsTheStepInProgress() throws {
        let fixture = try Fixture()
        try Self.withTaskProgress(nil) {
            var planned = try #require(fixture.rows()["planned"])
            planned.directory = "~/code/cmux"
            planned.agentStep = "Running tests"
            var options = SidebarLayoutOptions()
            options.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.directory])))
            let content = options.rowContent(planned, machine: nil)
            #expect(content.taskStep == "Fix the queue")
            #expect(content.detail == "Fix the queue" && content.now == nil, "the plan's step takes the second line")
            #expect(SidebarTaskProgress(done: 1, total: 3).stepNumber == 2)
            let label = WorkspaceRowView.accessibilityText(planned, content: content, tabCount: nil, presence: [])
            #expect(label.contains("Fix the queue, Step 2 of 3"), "\(label)")
            options.taskProgressLook = .hidden
            #expect(options.rowContent(planned, machine: nil).taskStep == nil)
        }
    }

    @Test func theSegmentsSayDoneNowAndLeft() {
        let bar = SidebarTaskBar(style: .segments, progress: SidebarTaskProgress(done: 2, total: 5, current: "Step 3"))
        let parts = SidebarTaskBarLayer.parts(bar, size: CGSize(width: 108, height: 2))
        #expect(parts.done.count == 2 && parts.current.count == 1 && parts.track.count == 2)
        #expect(parts.done[0].width == 20 && parts.current[0].minX == 44)
        let long = SidebarTaskBar(style: .segments, progress: SidebarTaskProgress(done: 30, total: 120))
        let fill = SidebarTaskBarLayer.parts(long, size: CGSize(width: 200, height: 2))
        #expect(fill.done == [CGRect(x: 0, y: 0, width: 50, height: 2)] && fill.track.count == 1, "120 steps draw one fill")
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
