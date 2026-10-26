import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The `Deadline` race helper (plans/cmux-next/chrome-parity/p06-scheduler.md, task 011, the R-timer recipe): the
/// first of the work, the limit and the caller's cancellation wins, the loser is cancelled and never waited for.
@Suite(.timeLimit(.minutes(1))) struct DeadlineTests {
    @Test func theWorkWinsBeforeTheLimit() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let value = try await Deadline(.seconds(5), clock: clock, ledger: ledger).run("fast") { 42 }
        #expect(value == 42)
        #expect(ledger.snapshot().isEmpty, "the limit never woke")
    }

    @Test func theLimitWinsAndCancelsTheWork() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let ended = FirstOutcome<Bool>()
        let timedOut = FirstOutcome<Bool>()
        let race = Task {
            try await Deadline(.seconds(5), clock: clock, ledger: ledger).run("hung", onTimeout: { timedOut.resolve(true) }) {
                for await _ in stream {}
                ended.resolve(Task.isCancelled)
                return 0
            }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        await #expect(throws: Deadline.Exceeded(label: "hung", limit: .seconds(5))) { try await race.value }
        #expect(await timedOut.value())
        #expect(await ended.value(), "the losing work was cancelled")
        #expect(ledger.snapshot().map(\.owner) == ["hung"])
        continuation.finish()
    }

    @Test func theWorksErrorIsThrown() async {
        let clock = ManualClock()
        await #expect(throws: DeadlineTestFailure.refused) {
            try await Deadline(.seconds(5), clock: clock).run("failing") { () async throws -> Int in throw DeadlineTestFailure.refused }
        }
    }

    @Test func valueIsNilWhenTheLimitWins() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let race = Task {
            await Deadline(.milliseconds(250), clock: clock, ledger: WakeupLedger()).value("reopen") { () async -> Int in
                for await _ in stream {}
                return 1
            }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(250))
        #expect(await race.value == nil)
        continuation.finish()
    }

    @Test func cancellingTheCallerEndsTheRaceAtOnce() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let race = Task {
            try await Deadline(.seconds(60), clock: clock, ledger: WakeupLedger()).run("cancelled") { () async -> Int in
                for await _ in stream {}
                return 1
            }
        }
        try await clock.waitForSleeper()
        race.cancel()
        await #expect(throws: CancellationError.self) { try await race.value }
        #expect(clock.sleeperCount == 0, "the limit's sleep was cancelled")
        continuation.finish()
    }
}

private enum DeadlineTestFailure: Error, Equatable {
    case refused
}
