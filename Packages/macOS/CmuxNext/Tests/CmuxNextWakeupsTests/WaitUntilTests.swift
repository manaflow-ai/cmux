import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// `waitUntil` wakes on the observable change that makes its condition hold, however many turns the
/// change takes to come, and a cancel (the time limit) ends it.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct WaitUntilTests {
    @Test func aConditionThatHoldsReturnsAtOnce() async throws {
        let model = Counter()
        model.value = 3
        try await waitUntil { model.value == 3 }
    }

    /// The change comes after more main-actor turns than any fixed yield budget would allow
    /// (the poll this replaces gave up after 2000 yields).
    @Test func itWakesOnTheChangeHoweverLateItComes() async throws {
        let model = Counter()
        let writer = Task { @MainActor in
            for _ in 0..<5_000 { await Task.yield() }
            model.value = 1
            for _ in 0..<5_000 { await Task.yield() }
            model.value = 2
        }
        try await waitUntil { model.value == 2 }
        #expect(model.value == 2)
        await writer.value
    }

    /// A cancel (the time limit, in a real failure) ends the wait with `CancellationError`, and the
    /// wait records the issue at the caller's line. withKnownIssue fails this test if no issue was
    /// recorded.
    @Test func cancellingTheWaitEndsItAndRecordsTheIssue() async {
        let model = Counter()
        let cancelled = Flag()
        let waiting = Task { @MainActor in
            await withKnownIssue("the cancelled wait records that its condition never held") {
                do {
                    try await waitUntil { model.value == 1 }
                } catch is CancellationError {
                    cancelled.set()
                }
            }
        }
        waiting.cancel()
        await waiting.value
        #expect(cancelled.isSet)
    }
}

/// An observable value the tests change.
@MainActor @Observable final class Counter {
    var value = 0
}
