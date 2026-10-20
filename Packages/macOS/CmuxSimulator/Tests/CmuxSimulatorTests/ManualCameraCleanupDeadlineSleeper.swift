import Foundation
@testable import CmuxSimulator

actor ManualCameraCleanupDeadlineSleeper: SimulatorWorkerSleeping {
    private let cleanupDeadline: Duration = .seconds(3)
    private var deadlineFired = false
    private var deadlineContinuation: CheckedContinuation<Void, Error>?

    func sleep(for duration: Duration) async throws {
        guard duration == cleanupDeadline else {
            try await ContinuousClock().sleep(for: .seconds(3_600))
            return
        }
        if deadlineFired { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                deadlineContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelDeadline() }
        }
    }

    func fireDeadline() {
        deadlineFired = true
        deadlineContinuation?.resume()
        deadlineContinuation = nil
    }

    private func cancelDeadline() {
        deadlineContinuation?.resume(throwing: CancellationError())
        deadlineContinuation = nil
    }
}
