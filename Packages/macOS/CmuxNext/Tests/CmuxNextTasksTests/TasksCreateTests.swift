@testable import CmuxNextTasks
import Foundation
import Testing

/// New Task: the pane's title field sends `task.create` through the intent
/// log with a client-chosen `task_` id and its own idempotency key.
@MainActor
struct TasksCreateTests {
    private func started(echo: Bool = false) -> (TasksModel, MockTasksSource) {
        let source = MockTasksSource()
        source.echoImmediately = echo
        let model = TasksModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func aTitleSendsTaskCreateWithAClientID() throws {
        let (model, source) = started()
        let id = try #require(model.createTask(title: "  Ship the Tasks page \n"))
        #expect(id.hasPrefix("task_"))
        let intent = try #require(model.pending.last)
        #expect(intent.wire.op == "task.create")
        #expect(intent.wire.params == ["id": .string(id), "title": .string("Ship the Tasks page")])
        #expect(model.visibleTasks.contains { $0.id == id && $0.title == "Ship the Tasks page" }, "shown before the echo")
        #expect(model.selection == id, "the user's new task is selected")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed[id]?.title == "Ship the Tasks page")
    }

    @Test func anEmptyTitleSendsNothing() {
        let (model, _) = started()
        #expect(model.createTask(title: "   \n") == nil)
        #expect(model.pending.isEmpty)
    }

    @Test func nothingIsCreatedWhileTheOwnerIsUnreachable() {
        let (model, source) = started()
        source.disconnect()
        #expect(model.createTask(title: "Offline") == nil)
        #expect(model.pending.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func mintedIDsAreValidAndDistinct() {
        let ids = (0..<20).map { _ in TasksModel.mintTaskID() }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            let rest = id.dropFirst("task_".count)
            #expect(id.hasPrefix("task_") && !rest.isEmpty && rest.count <= 64)
            #expect(rest.allSatisfy { $0.isNumber || ($0.isLowercase && $0.isASCII) || $0 == "-" || $0 == "_" })
        }
    }

    @Test func focusRequestsCount() {
        let (model, _) = started()
        #expect(model.newTaskFocusRequest == 0)
        model.focusNewTask()
        model.focusNewTask()
        #expect(model.newTaskFocusRequest == 2)
    }

    /// A request is honored once: a New Task field mounted later (a second
    /// window's tab) never takes focus for an old request.
    @Test func aFocusRequestIsTakenOnce() {
        let (model, _) = started()
        #expect(!model.takeNewTaskFocusRequest())
        model.focusNewTask()
        #expect(model.takeNewTaskFocusRequest())
        #expect(!model.takeNewTaskFocusRequest(), "a later mount finds nothing")
        model.focusNewTask()
        #expect(model.takeNewTaskFocusRequest())
    }
}
