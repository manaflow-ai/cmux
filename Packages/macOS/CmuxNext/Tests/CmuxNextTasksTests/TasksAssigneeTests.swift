@testable import CmuxNextTasks
import Foundation
import Testing

/// Decision T3: one Assignee control lists people and agents. A person is
/// `task.update {assignee}`, an agent is `task.delegate`, nobody is
/// `task.update {unassign}`; each goes through the intent log with its own
/// idempotency key.
@MainActor
struct TasksAssigneeTests {
    private func started(echo: Bool = false) -> (TasksModel, MockTasksSource) {
        let source = MockTasksSource()
        source.echoImmediately = echo
        let model = TasksModel(source: source)
        model.start()
        return (model, source)
    }

    private func task(_ model: TasksModel, _ id: String) throws -> TaskItem {
        try #require(model.visibleTasks.first { $0.id == id })
    }

    @Test func pickingAPersonSendsTaskUpdateWithTheAssignee() throws {
        let (model, source) = started()
        #expect(model.choose(.person("usr_austin"), for: "task_5"))
        let intent = try #require(model.pending.last)
        #expect(intent.wire.op == "task.update")
        #expect(intent.wire.params == ["task": .string("task_5"), "assignee": .string("usr_austin")])
        #expect(try task(model, "task_5").assignee?.stableID == "usr_austin", "the overlay shows it before the echo")
        #expect(model.confirmed["task_5"]?.assignee == nil, "intents never write the mirror")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed["task_5"]?.assignee?.stableID == "usr_austin")
    }

    @Test func pickingAnAgentSendsTaskDelegateWithAClientSession() throws {
        let (model, source) = started()
        #expect(model.choose(.agent(harness: "claude"), for: "task_5"))
        let intent = try #require(model.pending.last)
        #expect(intent.wire.op == "task.delegate")
        #expect(intent.wire.params["task"] == .string("task_5"))
        #expect(intent.wire.params["harness"] == .string("claude"))
        let session = try #require(intent.wire.params["session"]?.string)
        #expect(session.hasPrefix("asess_") && session.count <= 70)
        #expect(intent.wire.params["assignee"] == nil, "an agent is never sent as the assignee")
        let shown = try task(model, "task_5")
        #expect(shown.delegate?.harness == "claude")
        #expect(shown.delegate?.principal == "agt_claude-lawrence")
        #expect(shown.assignee?.stableID == "usr_lawrence", "the person the agent works for stays accountable")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed["task_5"]?.delegate?.harness == "claude")
        #expect(model.sessions[session]?.status == .pending)
    }

    @Test func unassignSendsTheUnassignFlag() throws {
        let (model, _) = started()
        #expect(model.choose(.nobody, for: "task_3"))
        let intent = try #require(model.pending.last)
        #expect(intent.wire.op == "task.update")
        #expect(intent.wire.params == ["task": .string("task_3"), "unassign": .bool(true)])
        #expect(try task(model, "task_3").assignee == nil)
    }

    @Test func pickingWhatTheTaskHasSendsNothing() {
        let (model, _) = started()
        #expect(!model.choose(.person("usr_lawrence"), for: "task_4"))
        #expect(!model.choose(.nobody, for: "task_5"))
        // task_1 has an active claude session (awaiting input).
        #expect(!model.choose(.agent(harness: "claude"), for: "task_1"))
        #expect(model.pending.isEmpty)
    }

    @Test func aFinishedSessionDoesNotBlockANewDelegation() {
        let (model, _) = started()
        // task_8's codex session failed; delegating again starts a new one.
        #expect(model.choose(.agent(harness: "codex"), for: "task_8"))
    }

    /// The owner keys agents per person (`agt_<harness>-<person>`): another
    /// person's active claude session neither blocks nor checks my claude.
    @Test func anotherPersonsAgentDoesNotBlockMine() throws {
        var seed = MockTasksSource.seed()
        let theirs = TaskAgent(principal: "agt_claude-austin", harness: "claude", onBehalfOf: "usr_austin")
        seed.sessions = seed.sessions.map { session in
            var session = session
            if session.task == "task_1" { session.agent = theirs }
            return session
        }
        let index = try #require(seed.tasks.firstIndex { $0.id == "task_1" })
        seed.tasks[index].delegate = theirs
        let model = TasksModel(source: MockTasksSource(snapshot: seed))
        model.start()
        #expect(!model.isCurrent(.agent(harness: "claude"), for: try task(model, "task_1")))
        #expect(model.choose(.agent(harness: "claude"), for: "task_1"))
    }

    @Test func eachPickHasItsOwnIdempotencyKey() {
        let (model, _) = started()
        model.choose(.person("usr_austin"), for: "task_5")
        model.choose(.agent(harness: "codex"), for: "task_6")
        #expect(Set(model.pending.map(\.key)).count == 2)
    }

    @Test func nothingIsSentWhileTheOwnerIsUnreachable() {
        let (model, source) = started()
        source.disconnect()
        #expect(!model.choose(.agent(harness: "claude"), for: "task_5"))
        #expect(model.pending.isEmpty)
    }

    @Test func choicesListMeFirstThenPeopleThenAgents() {
        let (model, _) = started()
        let choices = model.assigneeChoices
        #expect(choices.people == ["usr_lawrence", "usr_austin"])
        #expect(choices.agents == TaskAssigneeChoices.defaultAgents)
        model.knownAgents = ["claude"]
        #expect(model.assigneeChoices.agents == ["claude", "codex"], "an agent the mirror names stays listed")
    }

    @Test func checkMarksFollowTheVisibleTask() throws {
        let (model, _) = started()
        let first = try task(model, "task_1")
        #expect(model.isCurrent(.person("usr_lawrence"), for: first))
        #expect(model.isCurrent(.agent(harness: "claude"), for: first))
        #expect(!model.isCurrent(.nobody, for: first))
    }
}

/// My Tasks narrows the layouts to the local person's tasks; the empty
/// state shows only before the owner ever answered.
@MainActor
struct TasksScopeTests {
    @Test func mineShowsOnlyTasksAssignedToMe() {
        let model = TasksModel(source: MockTasksSource())
        model.start()
        #expect(model.shownTasks == model.visibleTasks)
        model.scope = .mine
        #expect(!model.shownTasks.isEmpty)
        #expect(model.shownTasks.allSatisfy { $0.assignee?.stableID == "usr_lawrence" })
        #expect(model.shownTasks.count == model.visibleTasks.filter { $0.assignee?.stableID == "usr_lawrence" }.count)
    }

    @Test func neverConnectedUntilTheFirstSnapshot() {
        let source = UnreachableTasksSource()
        let model = TasksModel(source: source)
        model.start()
        #expect(model.neverConnected)
        let connected = TasksModel(source: MockTasksSource())
        connected.start()
        #expect(!connected.neverConnected)
    }

    @Test func layoutsKeepTheSettingValues() {
        #expect(TasksLayout.allCases.map(\.rawValue) == ["list", "board", "inbox"])
        #expect(TasksLayout.fallback == .inbox)
    }
}

/// An owner that never answers (no `cmux task serve`).
@MainActor
private final class UnreachableTasksSource: TasksSource {
    func start(_ sink: @escaping @MainActor (TasksSourceEvent) -> Void) {
        sink(.connection(.disconnected("not running")))
    }

    func send(_ intent: TasksIntent) {}
    func stop() {}
}
