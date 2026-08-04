import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8960.
///
/// Claude Code no longer calls `TodoWrite`; it drives a task system through
/// `TaskCreate` / `TaskUpdate`. Those tools mutate one task per call, so the
/// store accumulates a list across events rather than expecting a whole list
/// in one payload — and it applies only completed calls, since a `PreToolUse`
/// event states intent and carries no task id.
@MainActor
@Suite("Workstream task-tool todos")
struct WorkstreamTaskToolTodoTests {
    private func toolCall(
        _ sessionId: String,
        tool: String,
        input: String,
        response: String? = nil,
        isError: Bool = false
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .postToolUse,
            source: "claude",
            toolName: tool,
            toolInputJSON: input,
            isError: isError,
            extraFieldsJSON: response.map { #"{"tool_response":\#($0)}"# }
        )
    }

    private func preToolUse(_ sessionId: String, tool: String, input: String) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            toolName: tool,
            toolInputJSON: input
        )
    }

    private func createTask(
        _ store: WorkstreamStore,
        _ sessionId: String,
        subject: String,
        id: String
    ) {
        store.ingest(toolCall(
            sessionId,
            tool: "TaskCreate",
            input: #"{"subject":"\#(subject)"}"#,
            response: #"{"task":{"id":"\#(id)","subject":"\#(subject)"}}"#
        ))
    }

    private func update(
        _ store: WorkstreamStore,
        _ sessionId: String,
        id: String,
        status: String
    ) {
        store.ingest(toolCall(
            sessionId,
            tool: "TaskUpdate",
            input: #"{"taskId":"\#(id)","status":"\#(status)"}"#,
            response: #"{"task":{"id":"\#(id)","status":"\#(status)"}}"#
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
        update(store, "s1", id: "1", status: "completed")
        update(store, "s1", id: "2", status: "in_progress")

        guard let todos = latestTodos(store) else {
            Issue.record("expected a todos payload from the task tools")
            return
        }
        #expect(todos.map(\.id) == ["1", "2", "3"])
        #expect(todos.map(\.content) == ["Read the code", "Write the fix", "Open a PR"])
        #expect(todos.map(\.state) == [.completed, .inProgress, .pending])
    }

    /// A pre-execution event states intent only: a create that is later denied
    /// must not leave a phantom row, and a delete must not drop a live one.
    @Test("PreToolUse never mutates the checklist")
    func preToolUseIsNotApplied() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(preToolUse("s1", tool: "TaskCreate", input: #"{"subject":"never ran"}"#))
        #expect(latestTodos(store) == nil)
        #expect(store.items.last?.kind == .toolUse)

        createTask(store, "s1", subject: "real", id: "1")
        store.ingest(preToolUse("s1", tool: "TaskUpdate", input: #"{"taskId":"1","status":"deleted"}"#))
        #expect(latestTodos(store)?.map(\.content) == ["real"])
    }

    @Test("A failed task call never mutates the checklist")
    func failedCallIsNotApplied() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "real", id: "1")
        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"deleted"}"#,
            response: #"{"error":"denied"}"#,
            isError: true
        ))
        #expect(latestTodos(store)?.map(\.content) == ["real"])
    }

    /// The id is assigned during execution, so a result without one describes
    /// a task nothing could ever address.
    @Test("A create with no id in its result is ignored")
    func createWithoutResultIdIsIgnored() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TaskCreate",
            input: #"{"subject":"orphan"}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store) == nil)
        #expect(store.ownedTaskIds(forWorkstream: "s1").isEmpty)
    }

    @Test("TaskUpdate status deleted removes the item")
    func taskUpdateDeleteRemoves() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "keep", id: "1")
        createTask(store, "s1", subject: "drop", id: "2")
        update(store, "s1", id: "2", status: "deleted")

        #expect(latestTodos(store)?.map(\.content) == ["keep"])
    }

    @Test("Deleting the last task publishes an empty list, not telemetry")
    func deletingLastTaskPublishesEmptyList() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "only", id: "1")
        update(store, "s1", id: "1", status: "deleted")

        #expect(store.items.last?.kind == .todos)
        #expect(latestTodos(store)?.isEmpty == true)
        // The id stays owned so the checklist sync can retire its row.
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["1"])
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

    /// Hooks installed mid-run, or a resumed session: the first event names a
    /// task cmux never saw created. It is adoptable when the payload
    /// describes it.
    @Test("A resumed session adopts tasks it never saw created")
    func resumedSessionAdoptsExistingTasks() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"12","status":"in_progress"}"#,
            response: #"{"task":{"id":"12","subject":"pre-existing task","status":"in_progress"}}"#
        ))
        #expect(latestTodos(store)?.map(\.id) == ["12"])
        #expect(latestTodos(store)?.first?.state == .inProgress)

        createTask(store, "s1", subject: "new work", id: "13")
        #expect(latestTodos(store)?.map(\.id) == ["12", "13"])
    }

    @Test("An unusable update claims no id")
    func ignoredUpdateClaimsNoId() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "real", id: "1")
        let before = store.ownedTaskIds(forWorkstream: "s1")

        // Status-only update for a task we never saw and cannot render.
        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"999","status":"in_progress"}"#,
            response: #"{"ok":true}"#
        ))
        #expect(store.ownedTaskIds(forWorkstream: "s1") == before)
    }

    @Test("An unknown status never clobbers a state already known")
    func unknownStatusKeepsExistingState() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "task", id: "1")
        update(store, "s1", id: "1", status: "completed")
        #expect(latestTodos(store)?.first?.state == .completed)

        update(store, "s1", id: "1", status: "blocked")
        #expect(latestTodos(store)?.first?.state == .completed)
    }

    /// A Claude session can be resumed under the same id, so SessionEnd must
    /// not discard the ownership map its checklist rows depend on.
    @Test("Ownership survives a resumable session end")
    func sessionEndKeepsOwnershipForResume() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "one", id: "1")
        store.ingest(WorkstreamEvent(sessionId: "s1", hookEventName: .sessionEnd, source: "claude"))
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["1"])

        // A resumed status-only update still lands on the existing row.
        update(store, "s1", id: "1", status: "completed")
        #expect(latestTodos(store)?.first?.state == .completed)
    }

    @Test("An empty TodoWrite snapshot clears the list")
    func emptyTodoWriteSnapshotClearsTheList() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.count == 1)

        store.ingest(toolCall("s1", tool: "TodoWrite", input: #"{"todos":[]}"#, response: #"{"ok":true}"#))
        #expect(store.items.last?.kind == .todos)
        #expect(latestTodos(store)?.isEmpty == true)
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["a"])

        // A payload with no list at all is still ignored.
        store.ingest(toolCall("s1", tool: "TodoWrite", input: #"{"unrelated":1}"#, response: #"{"ok":true}"#))
        #expect(store.items.last?.kind == .toolResult)
    }

    /// TaskUpdate can change a task's details alone; that must not overwrite
    /// the row's displayed subject.
    @Test("A details-only update keeps the task subject")
    func descriptionOnlyUpdateKeepsSubject() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "Ship the fix", id: "1")
        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","description":"now with more detail"}"#,
            response: #"{"task":{"id":"1","description":"now with more detail"}}"#
        ))
        #expect(latestTodos(store)?.first?.content == "Ship the fix")
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

    /// An agent that crashes never sends SessionEnd, so the map itself must be
    /// bounded rather than relying on that hook.
    @Test("Abandoned workstreams are evicted")
    func abandonedWorkstreamsAreEvicted() {
        let store = WorkstreamStore(ringCapacity: 5_000)
        for index in 0..<200 {
            createTask(store, "session-\(index)", subject: "task", id: "1")
        }
        #expect(store.ownedTaskIds(forWorkstream: "session-0").isEmpty)
        #expect(!store.ownedTaskIds(forWorkstream: "session-199").isEmpty)
    }

    /// Whole-list producers must accumulate ownership too, or a task dropped
    /// from a later snapshot could never have its checklist row retired.
    @Test("Whole-list snapshots union their ownership")
    func todoWriteUnionsOwnership() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first"},{"id":"b","content":"second"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["a", "b"])

        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first","status":"completed"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.map(\.id) == ["a"])
        // "b" is still owned, so its checklist row is retired rather than
        // mistaken for another producer's.
        #expect(store.ownedTaskIds(forWorkstream: "s1") == ["a", "b"])
    }

    /// Positional ids would hand one task's identity — and the checklist row
    /// and attachments bound to it — to a different task after a removal.
    @Test("Whole-list entries without ids keep identity across reorder and removal")
    func idlessSnapshotsUseContentDerivedIdentity() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"alpha"},{"content":"beta"},{"content":"gamma"}]}"#,
            response: #"{"ok":true}"#
        ))
        let first = latestTodos(store) ?? []
        let betaId = first.first { $0.content == "beta" }?.id

        // Remove the head and reorder: "beta" must keep the same identity.
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"gamma"},{"content":"beta"}]}"#,
            response: #"{"ok":true}"#
        ))
        let second = latestTodos(store) ?? []
        #expect(second.first { $0.content == "beta" }?.id == betaId)
        #expect(second.map(\.content) == ["gamma", "beta"])
    }

    /// Cancelled work is neither pending nor done; counting it as pending
    /// would overstate the remaining work in the progress readout.
    @Test("Cancelled whole-list entries are dropped, not shown as pending")
    func cancelledEntriesAreDropped() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"live"},{"id":"b","content":"dropped","status":"cancelled"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.map(\.content) == ["live"])
    }

    /// An unparseable payload must not read as "the agent cleared its plan",
    /// which would retire every row this workstream owns.
    @Test("An unparseable TodoWrite payload leaves the checklist alone")
    func unparseableTodoWriteDoesNotClear() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"id":"a","content":"first"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.count == 1)

        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .todoWrite,
            source: "opencode",
            toolInputJSON: #"{"unrelated":1}"#
        ))
        #expect(store.items.last?.kind == .toolUse)
        #expect(latestTodos(store)?.count == 1)
    }

    /// `replaceChecklist` rejects a whole replacement on a repeated id, so a
    /// snapshot listing the same wording twice must still yield distinct ids.
    @Test("Identical id-less entries stay distinct")
    func duplicateContentEntriesGetDistinctIds() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"write tests"},{"content":"write tests"}]}"#,
            response: #"{"ok":true}"#
        ))
        let todos = latestTodos(store) ?? []
        #expect(todos.count == 2)
        #expect(Set(todos.map(\.id)).count == 2)

        // The identity is still stable across repeated identical snapshots.
        let firstIds = todos.map(\.id)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"write tests"},{"content":"write tests"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.map(\.id) == firstIds)
    }

    /// A result can report failure in its own body without the event-level
    /// error flag; applying it would desynchronize the checklist for good.
    @Test("A result reporting success:false never mutates the checklist")
    func unsuccessfulResultIsNotApplied() {
        let store = WorkstreamStore(ringCapacity: 50)
        createTask(store, "s1", subject: "real", id: "1")
        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"deleted"}"#,
            response: #"{"success":false,"message":"task not found"}"#
        ))
        #expect(latestTodos(store)?.map(\.content) == ["real"])

        store.ingest(toolCall(
            "s1",
            tool: "TaskUpdate",
            input: #"{"taskId":"1","status":"completed"}"#,
            response: #"{"success":false}"#
        ))
        #expect(latestTodos(store)?.first?.state == .pending)
    }

    /// Without a producer id a same-sized snapshot cannot distinguish a
    /// reword from a removal plus an addition, so identity must never be
    /// carried across a text change: doing so grafts one task's attachments
    /// onto an unrelated one.
    @Test("An id-less text change mints a new identity rather than guessing")
    func idlessTextChangeFailsClosed() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"alpha"},{"content":"beta"}]}"#,
            response: #"{"ok":true}"#
        ))
        let alphaId = latestTodos(store)?.first { $0.content == "alpha" }?.id

        // Ambiguous: this is equally "alpha reworded to gamma" and "alpha
        // removed, gamma added". Nothing may inherit alpha's identity.
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"beta"},{"content":"gamma"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.map(\.content) == ["beta", "gamma"])
        #expect(latestTodos(store)?.allSatisfy { $0.id != alphaId } == true)
    }

    /// A removal is not an unambiguous reword, so identity must not be
    /// transplanted onto a surviving task.
    @Test("A removal does not transplant an id-less identity")
    func idlessRemovalDoesNotTransplantIdentity() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"alpha"},{"content":"beta"}]}"#,
            response: #"{"ok":true}"#
        ))
        let alphaId = latestTodos(store)?.first { $0.content == "alpha" }?.id

        store.ingest(toolCall(
            "s1",
            tool: "TodoWrite",
            input: #"{"todos":[{"content":"beta"}]}"#,
            response: #"{"ok":true}"#
        ))
        #expect(latestTodos(store)?.map(\.content) == ["beta"])
        #expect(latestTodos(store)?.first?.id != alphaId)
    }

    /// Seeding must respect the workstream cap on its own: a seeded entry
    /// whose next delta is ignored never reaches the eviction in apply.
    @Test("Seeded workstreams respect the retention bound")
    func seedingEnforcesTheWorkstreamCap() {
        let store = WorkstreamStore(ringCapacity: 5_000)
        for index in 0..<200 {
            store.seedTaskTodos(
                forWorkstream: "restored-\(index)",
                todos: [WorkstreamTaskTodo(id: "1", content: "task", state: .pending)]
            )
        }
        #expect(store.ownedTaskIds(forWorkstream: "restored-0").isEmpty)
        #expect(!store.ownedTaskIds(forWorkstream: "restored-199").isEmpty)
    }

    @Test("Non-task tool calls stay tool telemetry")
    func otherToolsUnaffected() {
        let store = WorkstreamStore(ringCapacity: 50)
        store.ingest(toolCall("s1", tool: "Bash", input: #"{"command":"echo hi"}"#))
        #expect(store.items.last?.kind == .toolResult)
    }
}
