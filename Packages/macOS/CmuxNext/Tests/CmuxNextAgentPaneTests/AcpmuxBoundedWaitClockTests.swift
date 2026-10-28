import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The daemon socket retry and the handoff's exit wait run on an injected clock.
@MainActor
struct AcpmuxBoundedWaitClockTests {
    /// The socket retry waits 100, 200, 400, then 500 ms, each with Backoff's tolerance, never past
    /// the caller's deadline, and records each wait in the ledger.
    @Test(.timeLimit(.minutes(1))) func theSocketRetryStepsByBackoffUpToTheDeadline() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let deadline: Duration = .milliseconds(1_450)
        let retries = Task {
            var backoff = AcpmuxHost.socketRetryBackoff
            for _ in 0..<5 {
                try await AcpmuxHost.socketRetryWait(&backoff, remaining: deadline - clock.now.offset, clock: clock, ledger: ledger)
            }
        }
        var at: Duration = .zero
        for step: Duration in [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(500), .milliseconds(250)] {
            try await clock.waitForSleeper()
            at += step
            #expect(clock.sleepRequests.last?.deadline.offset == at)
            #expect(clock.sleepRequests.last?.tolerance == Backoff.tolerance(for: step))
            clock.advance(by: step)
        }
        try await retries.value
        #expect(clock.now.offset == deadline)
        let waits = ledger.snapshot().filter { $0.owner == "agent-pane.daemon-socket" }.map(\.count).reduce(0, +)
        #expect(waits == 5)
    }

    /// A process that outlives the limit: the wait answers false at the limit, not before.
    @Test(.timeLimit(.minutes(1))) func theExitWaitAnswersFalseAtItsLimit() async throws {
        let clock = ManualClock()
        let wait = Task { await AgentPaneProcessExit(pid: getpid(), clock: clock).event(within: .seconds(15)) }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(15))
        clock.advance(by: .seconds(14))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await wait.value == false)
    }

    /// The exit event ends the wait at once, true, and drops its deadline.
    @Test(.timeLimit(.minutes(1))) func theExitWaitAnswersTrueAtTheExit() async throws {
        let clock = ManualClock()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let pid = child.processIdentifier
        let wait = Task { await AgentPaneProcessExit(pid: pid, clock: clock).event(within: .seconds(15)) }
        try await clock.waitForSleeper()
        child.terminate()
        #expect(await wait.value == true)
        #expect(clock.sleeperCount == 0)
    }
}
