import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8960.
///
/// Claude Code now reports its checklist through TaskCreate/TaskUpdate instead
/// of TodoWrite.  The hook events are still ordinary tool events, so the
/// store must recognize the tool names and accumulate their one-task deltas.
@MainActor
@Suite("Workstream task-tool todos")
struct WorkstreamTaskToolTodoTests {
    private func toolEvent(
        sessionId: String,
        hook: WorkstreamEvent.HookEventName = .preToolUse,
        tool: String,
        input: String,
        response: String? = nil
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: hook,
            source: "claude",
            toolName: tool,
            toolInputJSON: input,
            extraFieldsJSON: response.map { value in "{\"tool_response\":\(value)}" }
        )
    }

    private func latestTodos(_ store: WorkstreamStore) -> [WorkstreamTaskTodo]? {
        for item in store.items.reversed() {
            if case .todos(let todos) = item.payload {
                return todos
            }
        }
        return nil
    }

    @Test("TaskCreate and TaskUpdate accumulate into one list")
    func taskToolsAccumulate() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"Read the code"}"#,
            response: #"{"task":{"id":"1","subject":"Read the code"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"Write the fix"}"#,
            response: #"{"task":{"id":"2","subject":"Write the fix"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#,
            response: #"{"task":{"id":"1","status":"completed"}}"#
        ))

        guard let todos = latestTodos(store) else {
            Issue.record("expected a todos payload from TaskCreate/TaskUpdate")
            return
        }
        #expect(todos.map(\.id) == ["1", "2"])
        #expect(todos.map(\.content) == ["Read the code", "Write the fix"])
        #expect(todos.map(\.state) == [.completed, .pending])
    }

    @Test("TaskUpdate deleted removes the task")
    func taskUpdateDeleteRemoves() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"keep"}"#,
            response: #"{"task":{"id":"1","subject":"keep"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"deleted"}"#,
            response: #"{"task":{"id":"1","status":"deleted"}}"#
        ))

        #expect(latestTodos(store)?.isEmpty == true)
    }

    @Test("Legacy TodoWrite remains supported")
    func todoWriteRemainsSupported() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first","status":"in_progress"}]}"#
        ))

        #expect(latestTodos(store)?.first?.content == "first")
        #expect(latestTodos(store)?.first?.state == .inProgress)
    }

    @Test("Unrelated tools remain tool telemetry")
    func otherToolsUnaffected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "Bash",
            input: #"{"command":"echo hi"}"#
        ))

        #expect(store.items.last?.kind == .toolUse)
    }
}
