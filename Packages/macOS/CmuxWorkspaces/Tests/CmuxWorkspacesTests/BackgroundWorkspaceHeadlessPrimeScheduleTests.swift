import Testing

@testable import CmuxWorkspaces

@Suite
struct BackgroundWorkspaceHeadlessPrimeScheduleTests {
    @Test
    func timeoutRetriesTheSameWorkspaceWithoutRetainingAMount() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
        #expect(schedule.activeWorkspaceID == "first")
        #expect(schedule.retainedWorkspaceIDs.isEmpty)

        schedule.resolve(workspaceID: "first", resolution: .timeout)

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
        #expect(schedule.activeWorkspaceID == "first")
        #expect(schedule.retainedWorkspaceIDs.isEmpty)
    }

    @Test
    func completionAdvancesToTheNextPendingWorkspaceWithoutRetainingMounts() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
        schedule.resolve(workspaceID: "first", resolution: .completed)

        #expect(schedule.activeWorkspaceID == nil)
        #expect(schedule.retainedWorkspaceIDs.isEmpty)
        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["second"]) == "second")
        #expect(schedule.retainedWorkspaceIDs.isEmpty)
    }

    @Test
    func cancellationAndRemovalReleaseAllPrimeState() {
        var cancelledSchedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(cancelledSchedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first"]) == "first")

        cancelledSchedule.resolve(workspaceID: "first", resolution: .cancelled)

        #expect(cancelledSchedule.activeWorkspaceID == nil)
        #expect(cancelledSchedule.retainedWorkspaceIDs.isEmpty)

        var removedSchedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(removedSchedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first"]) == "first")

        removedSchedule.resolve(workspaceID: "first", resolution: .workspaceRemoved)

        #expect(removedSchedule.activeWorkspaceID == nil)
        #expect(removedSchedule.retainedWorkspaceIDs.isEmpty)
    }

    @Test
    func disappearingActiveWorkspaceSelectsOnlyOneRemainingWorkspace() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second", "third"]) == "first")

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["second", "third"]) == "second")
        #expect(schedule.activeWorkspaceID == "second")
        #expect(schedule.retainedWorkspaceIDs.isEmpty)
    }
}
