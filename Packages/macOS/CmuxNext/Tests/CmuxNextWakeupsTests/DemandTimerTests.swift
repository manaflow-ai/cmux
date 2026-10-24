import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A DemandTimer deadline whose action is isolated to an actor (the main actor for ThinScroller's
/// fade-out, TooltipPresenter, MadeAheadPanelStore, BackdropVideoView) can pass while that actor
/// is busy. A `schedule` or `cancel` the actor makes before its next turn must still win: the
/// replaced action never runs and is not a wakeup. The actions here run on ``ManualActor``, whose
/// turns the test gives, so "the deadline passed while the actor was busy" is exact, not timed.
/// The waits for a sleeper and for the actor's job are signals (CmuxNextWakeupsTestSupport); the
/// suite's time limit is the only bound on a guard that never arrives.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DemandTimerTests {
    private static let owner = "test.deadline"
    private static let delay: Duration = .seconds(1)

    private static func wakeups(_ ledger: WakeupLedger) -> [UInt64] {
        ledger.snapshot().filter { $0.owner == owner }.map(\.count)
    }

    /// Lets the deadline pass while the actor is busy: on return its fire waits for the actor.
    private static func passDeadlineWhileTheActorIsBusy(_ clock: ManualClock) async throws {
        try await clock.waitForSleeper()
        clock.advance(by: delay)
        try await ManualActor.executor.waitForJob()
    }

    @Test func aDeadlineRunsItsActionOnItsActorAndIsOneWakeup() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: Self.owner, clock: clock, ledger: ledger)
        let runs = RecordedRuns()
        timer.schedule(after: Self.delay) { @ManualActor in runs.append("first") }
        #expect(timer.isScheduled)
        try await Self.passDeadlineWhileTheActorIsBusy(clock)
        ManualActor.executor.runJobs()
        await timer.settled()
        #expect(runs.names == ["first"])
        #expect(Self.wakeups(ledger) == [1])
        #expect(!timer.isScheduled)
    }

    /// The scroller's case: the user pauses for the rest delay, then scrolls once more while main
    /// is busy. The new step's `schedule` comes before the fade-out's turn and replaces it.
    @Test func aScheduleBeforeTheActorsTurnReplacesADeadlineThatPassed() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: Self.owner, clock: clock, ledger: ledger)
        let runs = RecordedRuns()
        timer.schedule(after: Self.delay) { @ManualActor in runs.append("first") }
        try await Self.passDeadlineWhileTheActorIsBusy(clock)
        timer.schedule(after: Self.delay) { @ManualActor in runs.append("second") }
        // The actor's turn: the first deadline's fire runs in it, so the turn is not empty.
        #expect(ManualActor.executor.runJobs() > 0, "the passed deadline's fire never reached the actor")
        #expect(runs.names.isEmpty, "a deadline the next schedule replaced still ran its action")
        #expect(timer.isScheduled)

        try await Self.passDeadlineWhileTheActorIsBusy(clock)
        ManualActor.executor.runJobs()
        await timer.settled()
        #expect(runs.names == ["second"])
        #expect(Self.wakeups(ledger) == [1], "a replaced deadline was counted as a wakeup")
    }

    /// A tooltip hide, then a stale show: after `cancel()` the action does not run, also when the
    /// deadline passed before the cancel and its fire waits for the actor.
    @Test func aCancelBeforeTheActorsTurnDropsADeadlineThatPassed() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: Self.owner, clock: clock, ledger: ledger)
        let runs = RecordedRuns()
        timer.schedule(after: Self.delay) { @ManualActor in runs.append("first") }
        try await Self.passDeadlineWhileTheActorIsBusy(clock)
        timer.cancel()
        #expect(!timer.isScheduled)
        #expect(ManualActor.executor.runJobs() > 0, "the passed deadline's fire never reached the actor")
        await timer.settled()
        #expect(runs.names.isEmpty, "a cancelled deadline ran its action")
        #expect(Self.wakeups(ledger).isEmpty, "a cancelled deadline was counted as a wakeup")
    }

    /// `settled()` ends for a deadline that never fires, so a test that awaits it after a
    /// regression fails on its expectation instead of hanging.
    @Test func settledEndsForADeadlineCancelledWhileAsleepAndWhenNothingWasScheduled() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: Self.owner, clock: clock, ledger: ledger)
        await timer.settled() // nothing scheduled: returns at once
        let runs = RecordedRuns()
        timer.schedule(after: Self.delay) { @ManualActor in runs.append("first") }
        try await clock.waitForSleeper()
        timer.cancel()
        await timer.settled()
        #expect(runs.names.isEmpty)
        #expect(Self.wakeups(ledger).isEmpty)
    }
}
