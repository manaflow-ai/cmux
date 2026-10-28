import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Auth deadlines and backoffs sleep with a tolerance, so the kernel can fold their wakes into ones it
/// already has (plans/cmux-next/chrome-parity/p14-energy.md, Q2).
@Suite struct AuthWakeLeewayTests {
    @Test(arguments: [
        (Duration.seconds(-1), Duration.zero),
        (.zero, .zero),
        (.milliseconds(20), .zero),
        (.milliseconds(36), .milliseconds(8)),
        (.milliseconds(500), .milliseconds(50)),
        (.seconds(2), .milliseconds(200)),
        (.seconds(15), .seconds(1)),
        (.seconds(10 * 60), .seconds(1)),
    ])
    func leewayIsTenPercentBetweenEightMillisecondsAndOneSecond(delay: Duration, leeway: Duration) {
        #expect(delay.authWakeLeeway == leeway)
    }

    @Test func tokenDeadlineWaitAsksTheLeewayOfItsWholeBudget() async throws {
        let clock = ManualTestClock()
        let deadline = clock.authTokenDeadline(after: .seconds(5))
        let waiter = Task { try await deadline.wait() }

        await clock.waitUntilSleepers()
        #expect(clock.sleepTolerances == [.milliseconds(500)])
        clock.advance(by: .seconds(5))
        try await waiter.value
    }

    @Test func phaseTimeoutDeadlineAsksLeeway() async throws {
        let clock = ManualTestClock()
        let operationClock = ManualTestClock()

        let phase = Task {
            try await withAuthPhaseTimeout(
                .validateSession,
                duration: .seconds(15),
                clock: clock,
                log: AuthDebugLog(),
                registry: AuthPhaseTimeoutRegistry(),
                blocksRetriesWhileTimedOutOperationActive: false
            ) {
                try await operationClock.sleep(for: .seconds(3600))
            }
        }

        await clock.waitUntilSleepers()
        #expect(clock.sleepTolerances == [.seconds(1)])
        clock.advance(by: .seconds(15))
        await #expect(throws: AuthError.timedOut) { try await phase.value }
    }
}
