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
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let failure as SimulatorUIAutomationFailure {
                guard failure.code == "snapshot_capture_failed" else {
                    throw failure
                }
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
