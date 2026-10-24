import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A forced quit gives the last Home cache write a bounded chance (lead, 2026-10-24): the exit
/// comes when the write ends, or when the limit passes, never twice and never before either.
@Suite(.timeLimit(.minutes(1))) struct BoundedCompletionTests {
    /// Records each follow-up call and lets the test wait for the first.
    final class Calls: Sendable {
        let values = Mutex<[Bool]>([])
        let first = FirstOutcome<Bool>()
        func record(_ finished: Bool) {
            values.withLock { $0.append(finished) }
            first.resolve(finished)
        }
    }

    @Test func workThatEndsFirstRunsTheFollowUpAtOnceAndOnce() async throws {
        let clock = ManualClock()
        let calls = Calls()
        BoundedCompletion(clock: clock, ledger: WakeupLedger()).run(limit: .milliseconds(100), owner: "test") {
            // The work ends at once.
        } then: { calls.record($0) }
        #expect(await calls.first.value() == true)
        // The deadline was cancelled before the follow-up ran: nothing is left asleep on the clock.
        #expect(clock.sleeperCount == 0, "the limit's deadline outlived the work")
        clock.advance(by: .milliseconds(100))
        #expect(calls.values.withLock { $0 } == [true])
    }

    @Test func workThatHangsGivesWayAtTheLimit() async throws {
        let clock = ManualClock()
        let calls = Calls()
        let release = FirstOutcome<Void>()
        BoundedCompletion(clock: clock, ledger: WakeupLedger()).run(limit: .milliseconds(100), owner: "test") {
            await release.value()
        } then: { calls.record($0) }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(99))
        await Task.yield()
        #expect(calls.values.withLock { $0 }.isEmpty, "the follow-up ran before the limit")
        clock.advance(by: .milliseconds(1))
        #expect(await calls.first.value() == false)
        release.resolve(())
        await Task.yield()
        #expect(calls.values.withLock { $0 } == [false], "the late work ran the follow-up again")
    }
}
