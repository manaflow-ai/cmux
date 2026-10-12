import CmuxNextTasks
import Foundation
import Testing

/// The Tasks pane's optimistic rows (cx-jlqs, hq#1850): while an intent
/// waits for its echo, the pane shows what the owner's own reducer would
/// commit (cmux-tasks-core `tasks_preview` over the app FFI). Each test
/// sends through a real `TasksModel` on the demo owner with echoes held.
@MainActor
struct TasksPreviewTests {
    private func pane() -> (TasksModel, MockTasksSource) {
        let source = MockTasksSource()
        source.echoImmediately = false
        let model = TasksModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func aPendingCreateShowsTheOwnersNextKeyAndDefaultStatus() {
        let (model, _) = pane()
        #expect(model.send(.create(id: "task_new", title: "New", status: nil)))
        let created = model.visibleTasks.last
        #expect(created?.id == "task_new")
        #expect(created?.key == "CMX-12")
        #expect(created?.status == "st_backlog")
        #expect(created?.category == .backlog)
    }

    @Test func aPendingMoveOrdersTheTaskWhereTheOwnerWould() {
        let (model, _) = pane()
        model.move("task_5", after: nil, before: "task_1")
        #expect(model.visibleTasks.prefix(2).map(\.id) == ["task_5", "task_1"])
    }

    @Test func aPendingStatusChangeMovesTheTaskToItsCategory() {
        let (model, _) = pane()
        model.setStatus("task_5", to: "st_in_progress")
        let task = model.visibleTasks.first { $0.id == "task_5" }
        #expect(task?.status == "st_in_progress")
        #expect(task?.category == .started)
    }

    @Test func aPendingDelegationShowsTheAgentForMe() {
        let (model, _) = pane()
        #expect(model.send(.delegate(task: "task_5", session: "asess_new", harness: "codex")))
        let task = model.visibleTasks.first { $0.id == "task_5" }
        #expect(task?.delegate?.principal == "agt_codex-lawrence")
        #expect(task?.assignee?.stableID == "usr_lawrence")
    }

    @Test func theEchoReplacesThePreview() {
        let (model, source) = pane()
        #expect(model.send(.create(id: "task_new", title: "New", status: nil)))
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.visibleTasks.contains { $0.id == "task_new" })
    }
}
