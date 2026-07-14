import Testing

@testable import CmuxWorkspaces

@Suite
struct BackgroundWorkspaceHeadlessPrimeScheduleTests {
    @Test
    func timeoutAdvancesWithinThePassThenWrapsForRetry() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
        #expect(schedule.activeWorkspaceID == "first")

        schedule.resolve(workspaceID: "first", resolution: .timeout)

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "second")
        #expect(schedule.activeWorkspaceID == "second")

        schedule.resolve(workspaceID: "second", resolution: .timeout)

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
    }

    @Test
    func completionAdvancesToTheNextPendingWorkspace() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second"]) == "first")
        schedule.resolve(workspaceID: "first", resolution: .completed)

        #expect(schedule.activeWorkspaceID == nil)
        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["second"]) == "second")
    }

    @Test
    func cancellationAndRemovalReleaseAllPrimeState() {
        var cancelledSchedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(cancelledSchedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first"]) == "first")

        cancelledSchedule.resolve(workspaceID: "first", resolution: .cancelled)

        #expect(cancelledSchedule.activeWorkspaceID == nil)

        var removedSchedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(removedSchedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first"]) == "first")

        removedSchedule.resolve(workspaceID: "first", resolution: .workspaceRemoved)

        #expect(removedSchedule.activeWorkspaceID == nil)
    }

    @Test
    func disappearingActiveWorkspaceSelectsOnlyOneRemainingWorkspace() {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<String>()
        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["first", "second", "third"]) == "first")

        #expect(schedule.nextWorkspaceID(orderedPendingWorkspaceIDs: ["second", "third"]) == "second")
        #expect(schedule.activeWorkspaceID == "second")
    }
}
