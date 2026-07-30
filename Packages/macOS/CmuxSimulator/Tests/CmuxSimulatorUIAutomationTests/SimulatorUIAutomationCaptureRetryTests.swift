import Foundation
import Testing
@testable import CmuxSimulatorUIAutomation

@MainActor
@Suite("Simulator UI automation capture retry")
struct SimulatorUIAutomationCaptureRetryTests {
    @Test("Transient snapshot failures retry within the shared deadline")
    func transientFailuresRetry() async throws {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        let retry = SimulatorUIAutomationCaptureRetry(scheduler: timing)
        var attempts = 0

        let value: Int = try await retry.capture(until: 1_250) { _ in
            attempts += 1
            if attempts < 3 {
                throw simulatorSnapshotFailure()
            }
            return 42
        }

        #expect(value == 42)
        #expect(attempts == 3)
        #expect(timing.sleepCount == 2)
    }

    @Test("Non-transient failures are never retried")
    func nonTransientFailureStopsImmediately() async throws {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        let retry = SimulatorUIAutomationCaptureRetry(scheduler: timing)
        var attempts = 0

        do {
            _ = try await retry.capture(until: 1_250) { _ in
                attempts += 1
                throw SimulatorUIAutomationFailure(
                    code: "ui_state_changed",
                    message: "changed",
                    recoveryHint: "capture again"
                )
            } as Int
            Issue.record("Expected UI state failure")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "ui_state_changed")
        }

        #expect(attempts == 1)
        #expect(timing.sleepCount == 0)
    }

    @Test("The last transient failure escapes when the deadline expires")
    func deadlineStopsRetrying() async throws {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        let retry = SimulatorUIAutomationCaptureRetry(scheduler: timing)
        var attempts = 0

        do {
            _ = try await retry.capture(until: 1_100) { _ in
                attempts += 1
                throw simulatorSnapshotFailure()
            } as Int
            Issue.record("Expected snapshot failure")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "snapshot_capture_failed")
        }

        #expect(attempts == 1)
        #expect(timing.sleepCount == 1)
    }

    @Test("An expired deadline does not start a capture")
    func expiredDeadlineSkipsCapture() async {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        let retry = SimulatorUIAutomationCaptureRetry(scheduler: timing)
        var attempts = 0

        do {
            _ = try await retry.capture(until: 1_000) { _ in
                attempts += 1
                return 42
            } as Int
            Issue.record("Expected the expired capture deadline to fail")
        } catch {
            // The retry owns the deadline, so the capture closure must stay untouched.
        }

        #expect(attempts == 0)
        #expect(timing.sleepCount == 0)
    }

    private func simulatorSnapshotFailure() -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "snapshot_capture_failed",
            message: "temporarily unavailable",
            recoveryHint: "retry"
        )
    }
}

private final class AdvancingSimulatorUIAutomationTiming:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentMilliseconds: Int64
    private var recordedSleepCount = 0

    init(nowMilliseconds: Int64) {
        currentMilliseconds = nowMilliseconds
    }

    var sleepCount: Int {
        lock.withLock { recordedSleepCount }
    }

    func nowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock {
            currentMilliseconds += milliseconds
            recordedSleepCount += 1
        }
    }
}
