import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The test clock's wait for one timer of several (``ManualClock/waitForSleeper(dueBy:within:)``): a test with two
/// timers on one clock waits for the timer it moves the clock past next, with no poll of the clock's sleepers.
@Suite struct ManualClockTests {
    /// A timer that is due later sleeps on the clock already. The wait for a timer due by 250 ms returns only once
    /// that timer sleeps: the later timer does not end it.
    @Test func aWaitForATimerDueSoonIsNotEndedByATimerDueLater() async throws {
        let clock = ManualClock()
        let later = DemandTimer(owner: "ManualClockTests.later", clock: clock, ledger: WakeupLedger())
        let soon = DemandTimer(owner: "ManualClockTests.soon", clock: clock, ledger: WakeupLedger())
        later.schedule(after: .seconds(60)) {}
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines.map(\.offset) == [.seconds(60)])

        let due = clock.now.advanced(by: .milliseconds(250))
        soon.schedule(after: .milliseconds(250)) {}
        try await clock.waitForSleeper(dueBy: due)
        #expect(clock.sleeperDeadlines.contains(due), "the wait ended before the timer due by 250 ms slept: \(clock.sleeperDeadlines.map(\.offset))")

        // A wait for any timer still returns at once.
        try await clock.waitForSleeper()
        later.cancel()
        soon.cancel()
        #expect(clock.sleeperCount == 0)
    }
}
