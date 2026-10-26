@testable import CmuxNextHomeEngine
import CmuxNextWakeupsTestSupport
import Testing

/// PageCallDeadline over FirstOutcome (p10-stability-088): the first of the work's end, the
/// deadline and the caller's cancel answers; the work is cancelled once the call answered.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PageCallDeadlineTests {
    struct TimedOut: Error {}

    /// Work that waits until it is cancelled, and says so.
    static func endless(_ cancelled: AsyncStream<Void>.Continuation) -> @MainActor @Sendable () async throws -> Int {
        {
            let (never, _) = AsyncStream.makeStream(of: Void.self)
            await withTaskCancellationHandler {
                for await _ in never {}
            } onCancel: {
                cancelled.yield()
            }
            throw CancellationError()
        }
    }

    @Test func theWorksAnswerWins() async throws {
        let clock = ManualClock()
        let value = try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() }) { 7 }
        #expect(value == 7)
    }

    @Test func theDeadlineAnswersAndCancelsTheWork() async throws {
        let clock = ManualClock()
        let (cancels, cancelled) = AsyncStream.makeStream(of: Void.self)
        let call = Task { @MainActor in
            try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() },
                                              Self.endless(cancelled))
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        await #expect(throws: TimedOut.self) { try await call.value }
        var iterator = cancels.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func theCallersCancelAnswersAndCancelsTheWork() async throws {
        let clock = ManualClock()
        let (cancels, cancelled) = AsyncStream.makeStream(of: Void.self)
        let call = Task { @MainActor in
            try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() },
                                              Self.endless(cancelled))
        }
        try await clock.waitForSleeper()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        var iterator = cancels.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }
}
