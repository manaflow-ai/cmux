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

    @Test("Deadline exhaustion is distinct from a transient capture failure")
    func deadlineStopsRetrying() async throws {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        let retry = SimulatorUIAutomationCaptureRetry(scheduler: timing)
        var attempts = 0

        do {
            _ = try await retry.capture(until: 1_100) { _ in
                attempts += 1
                throw simulatorSnapshotFailure()
            } as Int
            Issue.record("Expected capture deadline exhaustion")
        } catch is SimulatorUIAutomationCaptureDeadlineExceeded {
            // Wait callers can translate this into wait_timeout without
            // confusing it with a broken accessibility worker.
        } catch {
            Issue.record("Expected capture deadline exhaustion, got \(error)")
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
