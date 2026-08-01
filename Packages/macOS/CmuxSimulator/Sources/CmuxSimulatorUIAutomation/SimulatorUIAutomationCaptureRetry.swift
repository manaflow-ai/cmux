/// Retries transient snapshots from bounded scheduler events.
@MainActor
struct SimulatorUIAutomationCaptureRetry {
    private let scheduler: any SimulatorUIAutomationScheduling
    private let intervalMilliseconds: Int64

    init(
        scheduler: any SimulatorUIAutomationScheduling,
        intervalMilliseconds: Int64 = 100
    ) {
        self.scheduler = scheduler
        self.intervalMilliseconds = intervalMilliseconds
    }

    func capture<Value>(
        until deadlineMilliseconds: Int64,
        retrying failureCodes: Set<String> = ["snapshot_capture_failed"],
        operation: @MainActor (Duration) async throws -> Value
    ) async throws -> Value {
        let beforeCapture = scheduler.monotonicNowMilliseconds()
        guard beforeCapture < deadlineMilliseconds else {
            throw SimulatorUIAutomationCaptureDeadlineExceeded()
        }
        do {
            return try await operation(.milliseconds(
                deadlineMilliseconds - beforeCapture
            ))
        } catch let failure as SimulatorUIAutomationFailure {
            guard failureCodes.contains(failure.code) else {
                throw failure
            }
            let events = SimulatorUIAutomationTickSequence(
                scheduler: scheduler,
                intervalMilliseconds: intervalMilliseconds,
                deadlineMilliseconds: deadlineMilliseconds,
                includesImmediateEvent: false
            )
            for try await eventMilliseconds in events {
                do {
                    return try await operation(.milliseconds(
                        deadlineMilliseconds - eventMilliseconds
                    ))
                } catch let retryFailure as SimulatorUIAutomationFailure {
                    guard failureCodes.contains(retryFailure.code) else {
                        throw retryFailure
                    }
                }
            }
            throw SimulatorUIAutomationCaptureDeadlineExceeded()
        }
    }
}
