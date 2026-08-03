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

    private func latestTodos(_ store: WorkstreamStore) -> [WorkstreamTaskTodo]? {
        for item in store.items.reversed() {
            if case .todos(let todos) = item.payload { return todos }
        }
        return nil
    }

    @Test("TaskCreate/TaskUpdate accumulate into a todo list")
    func taskToolsAccumulate() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"Read the code","description":"d"}"#))
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"Write the fix","description":"d"}"#))
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"Open a PR","description":"d"}"#))
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
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"keep"}"#))
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"drop"}"#))
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"2","status":"deleted"}"#))

        #expect(latestTodos(store)?.map(\.content) == ["keep"])
    }

    @Test("Task lists stay separate per workstream")
    func taskListsArePerSession() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"one"}"#))
        store.ingest(preToolUse("s2", tool: "TaskCreate", input: #"{"subject":"two"}"#))

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

    @Test("Non-task PreToolUse events stay tool-use telemetry")
    func otherToolsUnaffected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "Bash", input: #"{"command":"echo hi"}"#))
        #expect(store.items.last?.kind == .toolUse)
    }
}
