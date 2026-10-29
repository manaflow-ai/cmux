import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane's one-shot deadlines sleep with ``WakeLeeway``'s tolerance on
/// an injected clock, so the OS may coalesce their wakes, and still end exactly at their limit.
@MainActor
struct AgentPaneDeadlineLeewayTests {
    @Test(.timeLimit(.minutes(1))) func aHandshakeDeadlineAsksLeewayAndThrowsAtItsLimit() async throws {
        let clock = ManualClock()
        let (never, hold) = AsyncStream.makeStream(of: Int.self)
        let timedOut = TimeoutFlag()
        let call = Task {
            try await withAgentPaneDeadline(.seconds(2), label: "acpmux test", clock: clock,
                                            onTimeout: { timedOut.set() }) { () async throws -> Int in
                for await value in never { return value }
                throw CancellationError()
            }
        }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(2))
        // 2 s is a flexible deadline of 1 s or more: 10% leeway.
        #expect(clock.sleepRequests.last?.tolerance == .milliseconds(200))
        clock.advance(by: .seconds(2))
        await #expect(throws: AgentPaneDeadlineExceeded(label: "acpmux test")) { try await call.value }
        #expect(timedOut.value)
        hold.finish()
    }

    @Test(.timeLimit(.minutes(1))) func aHandshakeThatAnswersFirstReturnsItsValue() async throws {
        let clock = ManualClock()
        let value = try await withAgentPaneDeadline(.seconds(2), label: "acpmux test", clock: clock) { 7 }
        #expect(value == 7)
    }

    @Test(.timeLimit(.minutes(1))) func aReadThatNeverAnswersIsNilAtTheLimit() async throws {
        let clock = ManualClock()
        let (never, hold) = AsyncStream.makeStream(of: String.self)
        let read = Task {
            await agentPaneFirst(within: .milliseconds(400), clock: clock) { @MainActor () async -> String? in
                for await value in never { return value }
                return nil
            }
        }
        try await clock.waitForSleeper()
        // Below 1 s a flexible deadline gets the 8 ms wake alignment as its leeway.
        #expect(clock.sleepRequests.last?.tolerance == WakeLeeway.defaultAlignment)
        clock.advance(by: .milliseconds(400))
        #expect(await read.value == nil)
        hold.finish()
    }

    @Test(.timeLimit(.minutes(1))) func aMenuWithNoReportOpensAtTheLimitOnItsClock() async throws {
        let clock = ManualClock()
        let wait = AgentPaneMenuReportWait(limit: .milliseconds(250), clock: clock)
        let menu = Task { await wait.untilReported() }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .milliseconds(250))
        #expect(clock.sleepRequests.last?.tolerance == WakeLeeway.defaultAlignment)
        clock.advance(by: .milliseconds(250))
        await menu.value
    }

    @Test(.timeLimit(.minutes(1))) func aReportCancelsTheMenuDeadline() async throws {
        let clock = ManualClock()
        let wait = AgentPaneMenuReportWait(limit: .milliseconds(250), clock: clock)
        let menu = Task { await wait.untilReported() }
        try await clock.waitForSleeper()
        wait.reported()
        await menu.value
        #expect(clock.sleeperCount == 0)
    }
}

/// Set once by a deadline's `onTimeout`, read by the test after the call ends.
private nonisolated final class TimeoutFlag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
