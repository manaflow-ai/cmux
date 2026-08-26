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
        response: String? = nil,
        requestId: String? = nil,
        isError: Bool = false
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: hook,
            source: "claude",
            toolName: tool,
            toolInputJSON: input,
            isError: isError,
            requestId: requestId,
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

    @Test("A pre-tool snapshot cannot authorize completion")
    func preToolSnapshotIsNotAuthoritative() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"work","status":"completed"}]}"#
        ))
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)

        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"work","status":"completed"}]}"#,
            response: #"{"error":"denied"}"#,
            isError: true
        ))
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
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

    @Test("A failed create retires its provisional checklist row")
    func failedCreateRemovesProvisionalRow() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"will fail"}"#,
            requestId: "create-1"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"will fail"}"#,
            response: #"{"error":"denied"}"#,
            requestId: "create-1",
            isError: true
        ))
        #expect(latestTodos(store)?.isEmpty == true)
        #expect(store.ownedTaskIds(forWorkstream: "s1").isEmpty)
    }

    @Test("Late PreToolUse does not duplicate an authoritative create")
    func postThenPreCreateIsDeduplicated() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"one"}"#,
            response: #"{"task":{"id":"1","subject":"one"}}"#,
            requestId: "create-1"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"one"}"#,
            requestId: "create-1"
        ))
        #expect(latestTodos(store)?.map(\.id) == ["1"])
    }

    @Test("TaskGet accepts a single task response")
    func taskGetSingleTask() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskGet",
            input: #"{"taskId":"1"}"#,
            response: #"{"task":{"id":"1","subject":"inspect","status":"completed"}}"#
        ))
        #expect(latestTodos(store)?.first?.content == "inspect")
        #expect(latestTodos(store)?.first?.state == .completed)
    }

    @Test("TaskGet preserves other tasks and does not establish completeness")
    func taskGetDoesNotReplaceTaskList() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"pending work"}"#,
            response: #"{"task":{"id":"1","subject":"pending work"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"finished work"}"#,
            response: #"{"task":{"id":"2","subject":"finished work"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskGet",
            input: #"{"taskId":"2"}"#,
            response: #"{"task":{"id":"2","subject":"finished work","status":"completed"}}"#
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1", "2"])
        #expect(latestTodos(store)?.map(\.state) == [.pending, .completed])
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
    }

    @Test("A partial task discovery invalidates an older whole-list snapshot")
    func partialTaskDiscoveryInvalidatesCompleteness() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .todoWrite,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"known","status":"completed"}]}"#
        ))
        #expect(store.isTaskListComplete(forWorkstream: "s1"))

        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskGet",
            input: #"{"taskId":"2"}"#,
            response: #"{"task":{"id":"2","subject":"discovered","status":"completed"}}"#
        ))

        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
        #expect(latestTodos(store)?.map(\.id) == ["1", "2"])
    }

    @Test("A known TaskGet does not reauthorize a delta-only list")
    func knownTaskGetDoesNotReauthorizeCompleteness() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .todoWrite,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"known","status":"completed"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskGet",
            input: #"{"taskId":"1"}"#,
            response: #"{"task":{"id":"1","subject":"known","status":"completed"}}"#
        ))

        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
    }

    @Test("A pre-tool delta keeps completion authority disabled")
    func preToolDeltaInvalidatesCompleteness() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .todoWrite,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"known","status":"completed"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#
        ))
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)

        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#,
            response: #"{"task":{"id":"1","status":"completed"}}"#
        ))
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
    }

    @Test("A response-less TaskGet cannot authorize completion")
    func responseLessTaskGetIsRejected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .todoWrite,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"known","status":"completed"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskGet",
            input: #"{"taskId":"1"}"#
        ))

        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
    }

    @Test("A mismatched TaskUpdate response does not mutate the requested task")
    func mismatchedTaskUpdateIDsFailClosed() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"keep"}"#,
            response: #"{"task":{"id":"1","subject":"keep","status":"pending"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#,
            response: #"{"task":{"id":"2","subject":"other","status":"completed"}}"#
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1"])
        #expect(latestTodos(store)?.first?.state == .pending)
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["1"])
    }

    @Test("A post event with a different request ID still reconciles by payload")
    func mismatchedHookRequestIDsReconcile() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"reconcile me"}"#,
            requestId: "pre-hook-id"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"reconcile me"}"#,
            response: #"{"task":{"id":"1","subject":"reconcile me"}}"#,
            requestId: "post-hook-id"
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1"])
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["1"])
    }

    @Test("Out-of-order completions retain later pending operations")
    func outOfOrderCompletionsRetainPendingCreates() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"first"}"#,
            requestId: "first-pre"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"second"}"#,
            requestId: "second-pre"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"second"}"#,
            response: #"{"task":{"id":"2","subject":"second"}}"#,
            requestId: "second-post"
        ))

        #expect(latestTodos(store)?.map(\.content) == ["first", "second"])

        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"first"}"#,
            response: #"{"task":{"id":"1","subject":"first"}}"#,
            requestId: "first-post"
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1", "2"])
    }

    @Test("A failed TaskUpdate restores the pre-tool checklist")
    func failedTaskUpdateRestoresPreToolState() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .todoWrite,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"work","status":"pending"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#,
            response: #"{"error":"denied"}"#,
            isError: true
        ))

        #expect(latestTodos(store)?.first?.state == .pending)
    }

    @Test("A failed TodoWrite restores the previous snapshot")
    func failedTodoWriteRestoresPreviousSnapshot() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .preToolUse,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"1","content":"old","status":"pending"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"2","content":"new","status":"completed"}]}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"2","content":"new","status":"completed"}]}"#,
            response: #"{"error":"denied"}"#,
            isError: true
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1"])
        #expect(latestTodos(store)?.first?.state == .pending)
    }

    @Test("Overlapping task calls roll back only the failed operation")
    func overlappingTaskCallsKeepSuccessfulMutation() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"first"}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"second"}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"first"}"#,
            response: #"{"task":{"id":"1","subject":"first"}}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"second"}"#,
            response: #"{"error":"denied"}"#,
            isError: true
        ))

        #expect(latestTodos(store)?.map(\.id) == ["1"])
        #expect(latestTodos(store)?.first?.content == "first")
    }

    @Test("A response-less TaskCreate keeps its provisional row")
    func responseLessTaskCreateRemainsProjected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"pending create"}"#
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"pending create"}"#
        ))

        #expect(latestTodos(store)?.first?.content == "pending create")
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["pending-1"])
        #expect(store.isTaskListComplete(forWorkstream: "s1") == false)
    }

    @Test("Seeding discards post-hook frames from the pre-restart accumulator")
    func seedDiscardsStalePostOperations() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUse,
            tool: "TaskCreate",
            input: #"{"subject":"stale"}"#,
            response: #"{"error":"denied"}"#,
            requestId: "stale-post",
            isError: true
        ))
        store.seedTaskTodos(
            forWorkstream: "s1",
            todos: [WorkstreamTaskTodo(id: "existing", content: "existing", state: .pending)]
        )

        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"stale"}"#,
            requestId: "fresh-pre"
        ))

        #expect(latestTodos(store)?.map(\.content) == ["existing", "stale"])
    }

    @Test("A raw PostToolUseFailure rolls back a provisional task")
    func postToolUseFailureRollsBackProvisionalTask() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolEvent(
            sessionId: "s1",
            tool: "TaskCreate",
            input: #"{"subject":"will fail"}"#,
            requestId: "create-1"
        ))
        store.ingest(toolEvent(
            sessionId: "s1",
            hook: .postToolUseFailure,
            tool: "TaskCreate",
            input: #"{"subject":"will fail"}"#,
            requestId: "create-1"
        ))

        #expect(latestTodos(store)?.isEmpty == true)
        #expect(store.ownedTaskIds(forWorkstream: "s1").isEmpty)
    }
}
