import CmuxNextServerHelper
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The privileged helper's deadlines ask the OS for WakeLeeway's tolerance (p14-energy Q1). The
/// helper executable links no CmuxNextWakeups, so its runner keeps the tolerance of its one limit as
/// a constant; these tests keep that constant equal to the table and check what each deadline asks
/// the clock for.
struct ServerHelperLeewayTests {
    @Test(arguments: [Duration.milliseconds(500), .seconds(1), .seconds(30)])
    func theDeadlineAsksTheClockForTheCallersTolerance(limit: Duration) async throws {
        let clock = ManualClock(), never = ManualClock()
        let tolerance = WakeLeeway.window(delay: limit).tolerance
        let run = Task {
            try await ServerHelperDeadline().run(limit: limit, tolerance: tolerance, clock: clock, operation: {
                try await never.sleep(for: .seconds(3600), tolerance: nil)
                return 0
            }, onTimeout: {})
        }

        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: limit))
        #expect(request.tolerance == tolerance)

        clock.advance(by: limit)
        await #expect(throws: ServerHelperTimedOut.self) { try await run.value }
    }

    @Test func theHelpersToleranceIsWakeLeewaysForItsLimit() {
        #expect(ProcessFixRunner.helperTolerance == WakeLeeway.window(delay: ProcessFixRunner.helperLimit).tolerance)
        #expect(WakeLeeway.window(delay: .milliseconds(500)).tolerance == WakeLeeway.defaultAlignment)
    }

    @Test func theHelpersRunnerKillsAtItsLimitWithItsTolerance() async throws {
        let clock = ManualClock()
        let runner = ProcessFixRunner(clock: clock)
        let run = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }

        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: ProcessFixRunner.helperLimit))
        #expect(request.tolerance == ProcessFixRunner.helperTolerance)

        clock.advance(by: ProcessFixRunner.helperLimit)
        await #expect(throws: ServerHelperTimedOut.self) { try await run.value }
    }
}
