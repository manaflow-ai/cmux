@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A load the person would only answer "yes" to retries on its own (Leo, 2026-11-22: "vacuous decisions like that
/// should be just done"): spaced by a backoff while in sight, nothing armed out of sight, one attempt at once when it
/// comes back, and one quiet line only after the shared connection bound.
@MainActor
struct AutoRetryTests {
    /// No jitter, 1 s growing to 4 s, so the test knows each deadline.
    private static func make(_ clock: ManualClock, attempts: Counter) -> AutoRetry {
        AutoRetry(owner: "test", backoff: Backoff(initial: .seconds(1), maximum: .seconds(4), jitter: 0),
                  clock: clock) { attempts.count += 1 }
    }

    @MainActor final class Counter { var count = 0 }

    /// Lets the timer's main-actor action run after the clock moved.
    private static func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func aFailureRetriesAfterTheBackoffWithNoButtonAndNoLine() async throws {
        let clock = ManualClock()
        let attempts = Counter()
        let retry = Self.make(clock, attempts: attempts)
        retry.failed()
        #expect(retry.isFailing)
        #expect(!retry.showsNotice, "nothing shows at first")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        await Self.settle()
        #expect(attempts.count == 1)
        retry.failed()
        clock.advance(by: .seconds(1))
        await Self.settle()
        #expect(attempts.count == 1, "the second spacing is longer (2 s)")
        clock.advance(by: .seconds(1))
        await Self.settle()
        #expect(attempts.count == 2)
    }

    @Test func theQuietLineShowsOnlyAfterTheConnectionBound() async throws {
        let clock = ManualClock()
        let attempts = Counter()
        let retry = Self.make(clock, attempts: attempts)
        retry.setInSight(false) // only the notice timer runs
        retry.failed()
        try await clock.waitForSleeper()
        clock.advance(by: NoticeTiming.connectionQuiet - .milliseconds(1))
        await Self.settle()
        #expect(!retry.showsNotice)
        clock.advance(by: .milliseconds(1))
        await Self.settle()
        #expect(retry.showsNotice)
        retry.succeeded()
        #expect(!retry.showsNotice)
        #expect(!retry.isFailing)
    }

    @Test func outOfSightArmsNothingAndComingBackTriesAtOnce() async throws {
        let clock = ManualClock()
        let attempts = Counter()
        let retry = Self.make(clock, attempts: attempts)
        retry.failed()
        #expect(retry.isScheduled)
        retry.setInSight(false)
        #expect(!retry.isScheduled, "no retry timer while out of sight")
        clock.advance(by: .seconds(30))
        await Self.settle()
        #expect(attempts.count == 0)
        retry.setInSight(true)
        #expect(attempts.count == 1, "one attempt at once when it shows again")
    }

    @Test func aSuccessStopsTheLoop() async throws {
        let clock = ManualClock()
        let attempts = Counter()
        let retry = Self.make(clock, attempts: attempts)
        retry.failed()
        retry.succeeded()
        #expect(!retry.isScheduled)
        retry.setInSight(false)
        retry.setInSight(true)
        #expect(attempts.count == 0, "a load that works is not retried when it shows again")
    }
}
