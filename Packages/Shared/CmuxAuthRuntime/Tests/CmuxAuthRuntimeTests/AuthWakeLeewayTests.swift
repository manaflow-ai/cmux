import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Auth deadlines pass a tolerance to their clock, so the kernel can fire them
/// together with other wakes (p14-energy-067c).
struct AuthWakeLeewayTests {
    @Test func tokenDeadlineWaitPassesTenPercentTolerance() async throws {
        let clock = ToleranceRecordingClock()
        try await clock.authTokenDeadline(after: .seconds(2)).wait()
        let tolerances = await clock.log.tolerances
        #expect(tolerances == [Duration.milliseconds(200)])
    }

    @Test func browserAttemptDeadlinePassesTenPercentTolerance() async {
        let clock = ToleranceRecordingClock()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let attempt = Task<Bool, Never> {
            for await _ in gate {}
            return true
        }
        let resolved = await HostBrowserDeadline(clock: clock).resolve(attempt, timeout: 5)
        open.finish()
        attempt.cancel()
        #expect(resolved == false)
        let tolerances = await clock.log.tolerances
        #expect(tolerances == [Duration.milliseconds(500)])
    }
}

/// A clock whose sleeps return at once and record the tolerance they asked for.
private struct ToleranceRecordingClock: Clock {
    actor Log {
        private(set) var tolerances: [Duration?] = []

        func record(_ tolerance: Duration?) {
            tolerances.append(tolerance)
        }
    }

    typealias Instant = ContinuousClock.Instant

    let log = Log()

    var now: Instant { ContinuousClock.now }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await log.record(tolerance)
    }
}
