@testable import CmuxNextBrowserAutomation
import CmuxNextWakeupsTestSupport
import Testing

/// A driver call answers by its deadline even when WebKit never calls back, answers with the work
/// when it comes first, and a late answer reaches no one (one cancellable
/// OnceContinuation in place of the private resume-once box). The deadline sleeps on a
/// `ManualClock`, so nothing waits on the wall clock.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CallDeadlineTests {
    @Test func theWorkAnswersFirst() async throws {
        let clock = ManualClock()
        let answer = try await CallDeadline.run(.seconds(5), what: "eval", clock: clock) { () throws(DriverError) -> DriverJSON in
            .string("done")
        }
        #expect(answer == .string("done"))
    }

    @Test func theWorksErrorIsTheAnswer() async {
        let clock = ManualClock()
        let error = await #expect(throws: DriverError.self) {
            try await CallDeadline.run(.seconds(5), what: "eval", clock: clock) { () throws(DriverError) -> DriverJSON in
                throw DriverError(.closed, "gone")
            }
        }
        #expect(error?.code == .closed)
    }

    @Test func theDeadlineAnswersWhenWebKitNeverCallsBack() async throws {
        let clock = ManualClock()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let call = Task { @MainActor in
            try await CallDeadline.run(.seconds(5), what: "eval", clock: clock) { () throws(DriverError) -> DriverJSON in
                // WebKit calls back only when the test opens the gate, after the deadline answered.
                for await _ in gate { break }
                return .string("late")
            }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        let error = await #expect(throws: DriverError.self) { try await call.value }
        #expect(error?.code == .timeout)
        // The late answer finds the wait over: a no-op, not a second resume.
        open.yield()
        open.finish()
    }
}
