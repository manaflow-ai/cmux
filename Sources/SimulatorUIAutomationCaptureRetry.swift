struct SimulatorUIAutomationCaptureDeadlineExceeded: Error {}

/// Retries transient Simulator snapshot failures within one caller-owned deadline.
@MainActor
struct SimulatorUIAutomationCaptureRetry {
    private let timing: any SimulatorUIAutomationTiming
    private let intervalMilliseconds: Int64

    init(
        timing: any SimulatorUIAutomationTiming,
        intervalMilliseconds: Int64 = 100
    ) {
        self.timing = timing
        self.intervalMilliseconds = intervalMilliseconds
    }

    func capture<Value>(
        until deadlineMilliseconds: Int64,
        operation: @MainActor (Duration) async throws -> Value
    ) async throws -> Value {
        var lastFailure: SimulatorUIAutomationFailure?
        while true {
            try Task.checkCancellation()
            let beforeCapture = timing.nowMilliseconds()
            guard beforeCapture < deadlineMilliseconds else {
                if let lastFailure { throw lastFailure }
                throw SimulatorUIAutomationCaptureDeadlineExceeded()
            }
            do {
                return try await operation(.milliseconds(
                    deadlineMilliseconds - beforeCapture
                ))
            } catch let failure as SimulatorUIAutomationFailure {
                guard failure.code == "snapshot_capture_failed" else {
                    throw failure
                }
                lastFailure = failure
                let now = timing.nowMilliseconds()
                guard now < deadlineMilliseconds else {
                    throw failure
                }
                let remaining = deadlineMilliseconds - now
                try await timing.sleep(for: .milliseconds(
                    min(intervalMilliseconds, remaining)
                ))
            }
        }
    }
}
