import CmuxNextWakeupsTestSupport
import Testing

/// The shared manual clock: a sleeper wakes only when the clock reaches its deadline, a wait for a
/// sleeper returns only once one is asleep, and a cancel ends a sleep or a wait, also when it comes
/// before the task parks. Every guard that runs on this clock depends on these.
@Suite(.timeLimit(.minutes(1)))
struct ManualClockTests {
    @Test func aSleeperWakesOnlyWhenTheClockReachesItsDeadline() async throws {
        let clock = ManualClock()
        let woke = Flag()
        let sleeper = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(2)), tolerance: nil)
            woke.set()
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(!woke.isSet, "a sleeper woke before the clock reached its deadline")
        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(woke.isSet)
        #expect(clock.now == ManualClock.Instant(offset: .seconds(2)))
    }

    /// The case a vacuous guard would hide: `waitForSleeper` must not return before the sleeper
    /// parked. The sleeper reads `now` for its deadline in its own task, as a DemandTimer does, so
    /// a wait that returned early lets the advance run before that read: the deadline then lies
    /// past the advance, the sleeper never wakes, and the time limit fails the test.
    @Test func waitForSleeperReturnsOnlyOnceASleeperIsAsleep() async throws {
        let clock = ManualClock()
        let waiting = Task { try await clock.waitForSleeper() }
        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(1)), tolerance: nil) }
        try await waiting.value
        clock.advance(by: .seconds(1))
        try await sleeper.value
    }

    @Test func aDeadlineThatPassedReturnsAtOnce() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(5))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(5)), tolerance: nil)
    }

    @Test func cancellingASleeperEndsItsSleep() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(until: ManualClock.Instant(offset: .seconds(1)), tolerance: nil) }
        try await clock.waitForSleeper()
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }

    /// A task cancelled before it sleeps (its cancel handler runs first) still ends: the clock
    /// remembers the cancel until the sleep would park.
    @Test func aSleepCancelledBeforeItStartsEndsAtOnce() async throws {
        let clock = ManualClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: ManualClock.Instant(offset: .seconds(1)), tolerance: nil)
        }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }

    @Test func cancellingAWaitForASleeperEndsIt() async throws {
        let clock = ManualClock()
        let waiting = Task { try await clock.waitForSleeper() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

/// The waits refuse to run where nothing bounds them: without a time limit a missing signal would
/// hang the test job with no test named, so the wait fails the test at once instead. This suite has
/// no time limit on purpose; its tests never park.
@Suite struct UnboundedWaitTests {
    @Test func waitForSleeperFailsAtOnceInATestWithoutATimeLimit() async {
        let clock = ManualClock()
        let error = await #expect(throws: UnboundedWait.self) { try await clock.waitForSleeper() }
        #expect(error?.wait == "ManualClock.waitForSleeper()")
        #expect(error?.test != nil)
    }

    @Test func waitForJobFailsAtOnceInATestWithoutATimeLimit() async {
        let executor = ManualSerialExecutor()
        let error = await #expect(throws: UnboundedWait.self) { try await executor.waitForJob() }
        #expect(error?.wait == "ManualSerialExecutor.waitForJob()")
    }

    @Test func aWaitOutsideAnyTestFails() async {
        let clock = ManualClock()
        let outside = Task.detached { () -> UnboundedWait? in
            do {
                try await clock.waitForSleeper()
                return nil
            } catch let error as UnboundedWait {
                return error
            } catch {
                return nil
            }
        }
        let error = await outside.value
        #expect(error?.test == nil)
        #expect(error?.wait == "ManualClock.waitForSleeper()")
    }
}
