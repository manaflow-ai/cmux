import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeupsTestSupport
import Testing

@MainActor
struct MacScreenHubQuietTests {
    @Test func joiningWaitsForTheBoundAndDoesNotRestartWhileStillJoining() async throws {
        let clock = ManualClock()
        let quiet = MacScreenHubQuiet(clock: clock)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay - .milliseconds(1))
        #expect(quiet.note(.starting) == nil)
        #expect(quiet.revealed == 0)
        clock.advance(by: .milliseconds(1))
        await MacScreenDeviceSetupTests.settle { quiet.revealed == 1 }
        #expect(quiet.revealed == 1)
        #expect(quiet.note(.starting) == MacScreenHomeSnapshot.hubNote(.starting))
        #expect(quiet.note(.starting) != nil)
        #expect(clock.sleeperCount == 0)
    }

    @Test(arguments: [false, true])
    func recoveryCancelsAPendingNoticeAndTheNextDropGetsAFullHold(registered: Bool) async throws {
        let clock = ManualClock()
        let quiet = MacScreenHubQuiet(clock: clock)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        #expect(quiet.note(registered ? .starting : .ready, registered: registered) == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay)
        #expect(quiet.revealed == 0)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay - .milliseconds(1))
        #expect(quiet.note(.starting) == nil)
        clock.advance(by: .milliseconds(1))
        await MacScreenDeviceSetupTests.settle { quiet.revealed == 1 }
        #expect(quiet.revealed == 1)
        #expect(quiet.note(.starting) != nil)
    }

    @Test func recoveryAfterRevealAndSignOutBothResetTheHold() async throws {
        let clock = ManualClock()
        let quiet = MacScreenHubQuiet(clock: clock)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay)
        await MacScreenDeviceSetupTests.settle { quiet.revealed == 1 }
        #expect(quiet.note(.starting) != nil)
        #expect(quiet.note(.ready, registered: true) == nil)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        #expect(quiet.note(nil) == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay)
        #expect(quiet.revealed == 1)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: MacScreenHomeSnapshot.hubJoiningDelay)
        await MacScreenDeviceSetupTests.settle { quiet.revealed == 2 }
        #expect(quiet.revealed == 2)
        #expect(quiet.note(.starting) != nil)
    }

    @Test func failureRemainsImmediateAndCancelsTheJoiningTimer() async throws {
        let clock = ManualClock()
        let quiet = MacScreenHubQuiet(clock: clock)
        #expect(quiet.note(.starting) == nil)
        try await clock.waitForSleeper()
        let failed = DeviceHub.Status.failed("test failure")
        #expect(quiet.note(failed) == MacScreenHomeSnapshot.hubNote(failed))
        #expect(clock.sleeperCount == 0)
        #expect(quiet.note(.starting) == nil)
        #expect(quiet.note(nil) == nil)
    }
}
