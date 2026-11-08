import Foundation
import Testing
@testable import CmuxAgentChat

@Suite struct MarkdownImageLoadDeadlineTests {
    @Test func expiresOnlyAfterTheClockCompletesItsDeadline() async throws {
        let entered = AsyncStream<ContinuousClock.Instant>.makeStream()
        let advance = AsyncStream<Void>.makeStream()
        let clock = ControlledDeadlineClock(
            now: ContinuousClock().now,
            entered: entered.continuation,
            advance: advance.stream
        )
        let expired = DeadlineExpirationCounter()
        let task = MarkdownImageLoadDeadline(clock: clock, timeout: .seconds(15))
            .schedule { expired.increment() }
        var entries = entered.stream.makeAsyncIterator()
        let deadline = try #require(await entries.next())
        #expect(deadline == clock.now.advanced(by: .seconds(15)))
        #expect(expired.value == 0)
        advance.continuation.yield(())
        await task.value
        #expect(expired.value == 1)
    }

    @Test func completionCancelsThePendingExpiration() async throws {
        let entered = AsyncStream<ContinuousClock.Instant>.makeStream()
        let advance = AsyncStream<Void>.makeStream()
        let clock = ControlledDeadlineClock(
            now: ContinuousClock().now,
            entered: entered.continuation,
            advance: advance.stream
        )
        let expired = DeadlineExpirationCounter()
        let task = MarkdownImageLoadDeadline(clock: clock, timeout: .seconds(15))
            .schedule { expired.increment() }
        var entries = entered.stream.makeAsyncIterator()
        _ = try #require(await entries.next())
        task.cancel()
        advance.continuation.yield(())
        await task.value
        #expect(expired.value == 0)
    }
}

/// A one-shot clock whose sleep is completed by a test signal, with no wall wait.
private struct ControlledDeadlineClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let now: Instant
    let entered: AsyncStream<Instant>.Continuation
    let advance: AsyncStream<Void>
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        entered.yield(deadline)
        for await _ in advance { return }
    }
}

private final class DeadlineExpirationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
