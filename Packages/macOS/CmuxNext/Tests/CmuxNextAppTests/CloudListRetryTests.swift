@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A launch while offline (or while the Cloud API was down) left every Cloud workspace without
/// its machine until the person switched apps (#25595): a failed machine list was never read again
/// by itself. It is now read again on a capped backoff, a bounded number of times.
@MainActor
struct CloudListRetryTests {
    /// Longer than any backoff step with its jitter.
    private let step = Duration.seconds(60)

    @Test func aFailedListIsReadAgainAfterTheBackoff() async throws {
        let clock = ManualClock()
        let retry = CloudListRetry(clock: clock)
        let (reads, continuation) = AsyncStream<Void>.makeStream()
        retry.failed { continuation.yield() }
        #expect(retry.isScheduled)
        try await clock.waitForSleeper()
        clock.advance(by: step)
        var iterator = reads.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!retry.isScheduled)
    }

    @Test func aSecondFailureWhileARetryWaitsAddsNoOtherRetry() async throws {
        let clock = ManualClock()
        let retry = CloudListRetry(clock: clock)
        retry.failed {}
        retry.failed {}
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1)
        retry.cancel()
    }

    @Test func aListThatLandsCancelsTheWaitingRetry() async throws {
        let clock = ManualClock()
        let retry = CloudListRetry(clock: clock)
        var read = false
        retry.failed { read = true }
        try await clock.waitForSleeper()
        retry.reset()
        #expect(!retry.isScheduled)
        clock.advance(by: step)
        await Task.yield()
        #expect(!read)
    }

    @Test func retriesStopAfterTheTimedBudget() {
        let retry = CloudListRetry(clock: ManualClock())
        var scheduled = 0
        // Each failure that finds no retry waiting spends one timed attempt.
        for _ in 0..<(CloudListRetry.timedRetries + 3) {
            retry.failed {}
            if retry.isScheduled { scheduled += 1 }
            retry.cancel()
        }
        #expect(scheduled == CloudListRetry.timedRetries)
        // Another account (or a list that landed) gets the whole budget again.
        retry.reset()
        retry.failed {}
        #expect(retry.isScheduled)
        retry.cancel()
    }
}
