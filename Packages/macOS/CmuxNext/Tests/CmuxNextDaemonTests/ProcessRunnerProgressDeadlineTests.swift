import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Exercise the production watchdog with virtual time and progress. No subprocess or wall-clock
/// hour is needed; cancellation must remove its only pending sleep before the owner returns.
struct ProcessRunnerProgressDeadlineTests {
    @Test(.timeLimit(.minutes(1))) func activeProgressOutlivesAnHourThenStallEndsTheWatchdog() async throws {
        let clock = ManualClock()
        let writes = Mutex(0)
        // task-owner: this test awaits completion after the final idle window; defer cancels on failure.
        let watchdog = Task {
            try await ProcessRunner.waitForDeadline(timeout: nil, progressIdle: .seconds(30), clock: clock,
                                                    progress: { writes.withLock { $0 } })
        }
        defer { watchdog.cancel() }
        for _ in 0..<130 {
            try await clock.waitForSleeper()
            writes.withLock { $0 += 1 }
            clock.advance(by: .seconds(30))
        }
        try await clock.waitForSleeper()
        #expect(clock.now.offset == .seconds(3_900), "active progress survived the old one-hour cap")
        clock.advance(by: .seconds(30)) // No write: a stalled transfer must still terminate.
        try await watchdog.value
        #expect(clock.sleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingIdleOnlyWatchdogRemovesItsSleep() async throws {
        let clock = ManualClock()
        // task-owner: cancelled and awaited below; no timer survives the upload owner.
        let watchdog = Task {
            try await ProcessRunner.waitForDeadline(timeout: nil, progressIdle: .seconds(30), clock: clock, progress: { 0 })
        }
        defer { watchdog.cancel() }
        try await clock.waitForSleeper()
        watchdog.cancel()
        await #expect(throws: CancellationError.self) { try await watchdog.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func existingHardDeadlineStillWinsDespiteProgress() async throws {
        let clock = ManualClock()
        let writes = Mutex(0)
        // task-owner: this test awaits its hard deadline; defer cancels on failure.
        let watchdog = Task {
            try await ProcessRunner.waitForDeadline(timeout: .seconds(60), progressIdle: .seconds(30), clock: clock,
                                                    progress: { writes.withLock { $0 } })
        }
        defer { watchdog.cancel() }
        for _ in 0..<2 {
            try await clock.waitForSleeper()
            writes.withLock { $0 += 1 }
            clock.advance(by: .seconds(30))
        }
        try await watchdog.value
        #expect(clock.now.offset == .seconds(60))
        #expect(clock.sleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func existingElapsedOnlyDeadlineRemainsOneShot() async throws {
        let clock = ManualClock()
        // task-owner: this test awaits its elapsed deadline; defer cancels on failure.
        let watchdog = Task {
            try await ProcessRunner.waitForDeadline(timeout: .seconds(45), progressIdle: nil, clock: clock, progress: nil)
        }
        defer { watchdog.cancel() }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(44))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await watchdog.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func missingBothDeadlinesRefusesBeforeLaunchingAChild() async {
        await #expect(throws: DaemonError.self) {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [],
                                            environment: nil, timeout: nil, progressIdle: nil, clock: ContinuousClock())
        }
    }
}
