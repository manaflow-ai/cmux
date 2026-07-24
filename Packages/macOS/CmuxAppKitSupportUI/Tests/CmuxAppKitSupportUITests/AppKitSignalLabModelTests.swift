import Testing
@testable import CmuxAppKitSupportUI

@MainActor
@Suite("AppKit signal todo model")
struct AppKitSignalLabModelTests {
    @Test func addDraftTaskTrimsSelectsAndClearsComposer() {
        let model = AppKitSignalLabModel()
        let initialCount = model.tasks.get().count

        #expect(model.canAddTask.get() == false)
        model.draftTaskTitle.set("  Write signal demo  ")
        #expect(model.canAddTask.get() == true)

        model.addDraftTask()

        #expect(model.tasks.get().count == initialCount + 1)
        #expect(model.tasks.get().first?.title == "Write signal demo")
        #expect(model.tasks.get().first?.status == .queued)
        #expect(model.selectedTask.get()?.title == "Write signal demo")
        #expect(model.draftTaskTitle.get().isEmpty)
        #expect(model.canAddTask.get() == false)
    }

    @Test func emptyDraftDoesNotAddTask() {
        let model = AppKitSignalLabModel()
        let initialTasks = model.tasks.get()

        model.draftTaskTitle.set("   ")
        model.addDraftTask()

        #expect(model.tasks.get() == initialTasks)
    }

    @Test func completionToggleUpdatesTaskAndDerivedMetrics() {
        let model = AppKitSignalLabModel()
        let initialCompleted = model.metrics.get().completedCount

        model.toggleCompletion(at: 0)

        #expect(model.tasks.get().first?.status == .complete)
        #expect(model.tasks.get().first?.progress == 1)
        #expect(model.metrics.get().completedCount == initialCompleted + 1)

        model.toggleCompletion(at: 0)

        #expect(model.tasks.get().first?.status == .queued)
        #expect(model.tasks.get().first?.progress == 0)
        #expect(model.metrics.get().completedCount == initialCompleted)
    }

    @Test func clearCompletedRemovesTodosAndRepairsSelection() {
        let model = AppKitSignalLabModel()
        model.selectTask(at: 5)
        let removedID = model.selectedTaskID.get()

        model.clearCompletedTasks()

        #expect(model.tasks.get().count == 6)
        #expect(model.tasks.get().allSatisfy { $0.status != .complete })
        #expect(model.selectedTaskID.get() != removedID)
        #expect(model.selectedTask.get() != nil)
        #expect(model.metrics.get().completedCount == 0)
    }
}
