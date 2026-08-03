import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8960.
///
/// Claude Code no longer calls `TodoWrite`; it drives a task system through
/// `TaskCreate` / `TaskUpdate`, delivered to cmux as `PreToolUse` events with
/// matcher `""`. Those tools mutate one task per call, so the store has to
/// accumulate a list across events rather than expecting a whole list in one
/// payload.
@MainActor
@Suite("Workstream task-tool todos")
struct WorkstreamTaskToolTodoTests {
    private func preToolUse(
        _ sessionId: String,
        tool: String,
        input: String
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            toolName: tool,
            toolInputJSON: input
        )
    }

    private func postToolUse(
        _ sessionId: String,
        tool: String,
        response: String
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .postToolUse,
            source: "claude",
            toolName: tool,
            extraFieldsJSON: #"{"tool_response":\#(response)}"#
        )
    }

    /// Drives one TaskCreate through both halves of its lifecycle: the
    /// PreToolUse call that creates the row and the PostToolUse result that
    /// names it.
    private func createTask(
        _ store: WorkstreamStore,
        _ sessionId: String,
        subject: String,
        id: String
    ) {
        store.ingest(preToolUse(sessionId, tool: "TaskCreate", input: #"{"subject":"\#(subject)"}"#))
        store.ingest(postToolUse(
            sessionId,
            tool: "TaskCreate",
            response: #"{"task":{"id":"\#(id)","subject":"\#(subject)"}}"#
        ))
    }

    private func latestTodos(_ store: WorkstreamStore) -> [WorkstreamTaskTodo]? {
        for item in store.items.reversed() {
            if case .todos(let todos) = item.payload { return todos }
        }
        return nil
    }

    @Test("TaskCreate/TaskUpdate accumulate into a todo list")
    func taskToolsAccumulate() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "Read the code", id: "1")
        createTask(store, "s1", subject: "Write the fix", id: "2")
        createTask(store, "s1", subject: "Open a PR", id: "3")
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"1","status":"completed"}"#))
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"2","status":"in_progress"}"#))

        guard let todos = latestTodos(store) else {
            Issue.record("expected a todos payload from the task tools")
            return
        }
        #expect(todos.map(\.id) == ["1", "2", "3"])
        #expect(todos.map(\.content) == ["Read the code", "Write the fix", "Open a PR"])
        #expect(todos.map(\.state) == [.completed, .inProgress, .pending])
    }

    @Test("TaskUpdate status deleted removes the item")
    func taskUpdateDeleteRemoves() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "keep", id: "1")
        createTask(store, "s1", subject: "drop", id: "2")
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"2","status":"deleted"}"#))

        #expect(latestTodos(store)?.map(\.content) == ["keep"])
    }

    @Test("Task lists stay separate per workstream")
    func taskListsArePerSession() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "one", id: "1")
        createTask(store, "s2", subject: "two", id: "1")

        let s1 = store.items.last(where: { $0.workstreamId == "s1" })
        let s2 = store.items.last(where: { $0.workstreamId == "s2" })
        if case .todos(let todos) = s1?.payload {
            #expect(todos.map(\.content) == ["one"])
        } else {
            Issue.record("expected todos for s1")
        }
        if case .todos(let todos) = s2?.payload {
            #expect(todos.map(\.content) == ["two"])
        } else {
            Issue.record("expected todos for s2")
        }
    }

    @Test("TodoWrite arriving as a PreToolUse tool name still fills the list")
    func todoWriteAsToolName() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first","status":"in_progress"},{"id":"b","content":"second","status":"pending"}]}"#
        ))

        #expect(latestTodos(store)?.map(\.content) == ["first", "second"])
        #expect(latestTodos(store)?.first?.state == .inProgress)
    }

    @Test("A create keeps a provisional id until the tool result names it")
    func provisionalIdIsReplacedByAuthoritativeId() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"probe"}"#))
        // Before the result lands the row exists but is not claiming to be
        // Claude's "1" — nothing may guess ids from call order.
        #expect(latestTodos(store)?.first?.id.hasPrefix("cmux-pending-") == true)

        store.ingest(postToolUse(
            "s1",
            tool: "TaskCreate",
            response: #"{"task":{"id":"7","subject":"probe"}}"#
        ))
        #expect(latestTodos(store)?.map(\.id) == ["7"])
        // The provisional id stays owned so the checklist row written under
        // it is retired rather than left behind as a duplicate.
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["cmux-pending-1", "7"])

        // An update against the authoritative id now lands on the real row.
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"7","status":"completed"}"#))
        #expect(latestTodos(store)?.first?.state == .completed)
    }

    @Test("Deleting the last task publishes an empty list, not telemetry")
    func deletingLastTaskPublishesEmptyList() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "only", id: "1")
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"1","status":"deleted"}"#))

        #expect(store.items.last?.kind == .todos)
        #expect(latestTodos(store)?.isEmpty == true)
        // The ids stay owned so the checklist sync retires their rows.
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["cmux-pending-1", "1"])
    }

    @Test("Session end retires the accumulator")
    func sessionEndClearsAccumulator() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "one", id: "1")
        #expect(!store.ownedTaskIds(forWorkstream: "s1").isEmpty)

        store.ingest(WorkstreamEvent(sessionId: "s1", hookEventName: .sessionEnd, source: "claude"))
        #expect(store.ownedTaskIds(forWorkstream: "s1").isEmpty)
    }

    @Test("Retained tasks stay bounded")
    func retainedTasksAreBounded() {
        let store = WorkstreamStore(ringCapacity: 5_000)
        let overflow = WorkstreamTaskToolTodos.maxRetainedTodos + 20
        for index in 0..<overflow {
            createTask(store, "s1", subject: "task \(index)", id: "\(index)")
        }
        #expect(latestTodos(store)?.count == WorkstreamTaskToolTodos.maxRetainedTodos)
        #expect(store.ownedTaskIds(forWorkstream: "s1").count <= WorkstreamTaskToolTodos.maxOwnedIds)
    }

    @Test("A resumed session adopts tasks it never saw created")
    func resumedSessionAdoptsExistingTasks() {
        let store = WorkstreamStore(ringCapacity: 50)
        // Hooks installed mid-run: the first thing cmux sees is an update for
        // a task id far above anything it could have minted.
        store.ingest(preToolUse(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"12","subject":"pre-existing task","status":"in_progress"}"#
        ))
        #expect(latestTodos(store)?.map(\.id) == ["12"])
        #expect(latestTodos(store)?.first?.state == .inProgress)

        // A later create still gets its own authoritative id; nothing is
        // inferred from the counter the resumed session left behind.
        createTask(store, "s1", subject: "new work", id: "13")
        #expect(latestTodos(store)?.map(\.id) == ["12", "13"])
    }

    @Test("An unknown status never clobbers a state already known")
    func unknownStatusKeepsExistingState() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "task", id: "1")
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"1","status":"completed"}"#))
        #expect(latestTodos(store)?.first?.state == .completed)

        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"1","status":"blocked"}"#))
        #expect(latestTodos(store)?.first?.state == .completed)
    }

    @Test("An unusable update claims no id")
    func ignoredUpdateClaimsNoId() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "real", id: "1")
        let before = store.ownedTaskIds(forWorkstream: "s1")

        // Status-only update for a task we never saw and cannot render.
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"999","status":"in_progress"}"#))

        #expect(store.ownedTaskIds(forWorkstream: "s1") == before)
        #expect(store.items.last?.kind == .toolUse)
    }

    @Test("Non-task PreToolUse events stay tool-use telemetry")
    func otherToolsUnaffected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "Bash", input: #"{"command":"echo hi"}"#))
        #expect(store.items.last?.kind == .toolUse)
    }
}
