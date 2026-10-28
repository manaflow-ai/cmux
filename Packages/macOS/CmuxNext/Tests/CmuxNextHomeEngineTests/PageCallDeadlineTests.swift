@testable import CmuxNextHomeEngine
import CmuxNextWakeupsTestSupport
import Testing

/// A page call answers once: with its work when it ends first, with `onTimeout` at the deadline,
/// with `CancellationError` when the page cancels it; the work is cancelled whenever it did not
/// answer (one cancellable OnceContinuation in place of the private resume-once
/// box). The deadline sleeps on a `ManualClock`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PageCallDeadlineTests {
    struct TimedOut: Error {}
    struct Refused: Error {}

    /// Work that never answers by itself: it ends only when its task is cancelled, and says so.
    @MainActor final class EndlessWork {
        private(set) var ran = false
        /// Never yields: the work answers only by its cancellation.
        private let gate = AsyncStream<Int>.makeStream()
        private let stopped = AsyncStream<Void>.makeStream()

        func run() async throws -> Int {
            ran = true
            for await value in gate.stream { return value }
            stopped.continuation.yield()
            stopped.continuation.finish()
            throw CancellationError()
        }

        /// Returns once the work saw its cancellation.
        func waitUntilStopped() async {
            for await _ in stopped.stream { return }
        }
    }

    @MainActor final class Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test func theWorkAnswersFirst() async throws {
        let clock = ManualClock()
        let answer = try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() }) { 7 }
        #expect(answer == 7)
    }

    @Test func theWorksErrorIsTheAnswer() async {
        let clock = ManualClock()
        await #expect(throws: Refused.self) {
            try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() }) { () throws -> Int in
                throw Refused()
            }
        }
    }

    @Test func theDeadlineAnswersAndStopsTheWork() async throws {
        let clock = ManualClock()
        let work = EndlessWork()
        let timeouts = Counter()
        let call = Task { @MainActor in
            try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: {
                timeouts.bump()
                return TimedOut()
            }) { try await work.run() }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        await #expect(throws: TimedOut.self) { try await call.value }
        #expect(timeouts.count == 1)
        await work.waitUntilStopped()
    }

    @Test func thePagesCancelAnswersAtOnceAndStopsTheWork() async throws {
        let clock = ManualClock()
        let work = EndlessWork()
        let timeouts = Counter()
        let call = Task { @MainActor in
            try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: {
                timeouts.bump()
                return TimedOut()
            }) { try await work.run() }
        }
        try await clock.waitForSleeper()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(timeouts.count == 0)
        await work.waitUntilStopped()
    }

    @Test func aCallCancelledBeforeItStartsRunsNoWork() async {
        let clock = ManualClock()
        let work = EndlessWork()
        let call = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PageCallDeadline.answer(within: .seconds(5), clock: clock, onTimeout: { TimedOut() }) {
                try await work.run()
            }
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(!work.ran)
    }
}
