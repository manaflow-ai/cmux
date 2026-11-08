import Foundation
import Testing
@testable import CmuxUpdater

/// Immediate for the sub-second plumbing delays; parks second-or-longer deadlines until the test
/// releases them with ``fireDeadlines()`` so watchdog time is explicit.
actor TestDeadlineClock: UpdateClock {
    private var parked: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration >= .seconds(1) else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelParked(id) }
        }
    }

    func fireDeadlines() {
        let waiters = parked
        parked = [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    func fireDeadlineWhenReady() async {
        // A test may request a deadline and immediately release it before the task running
        // `sleep(for:)` reaches the actor. Poll that real registration signal without timing
        // sleeps, but bound the poll so a missing deadline fails instead of hanging the suite.
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(2))
        while parked.isEmpty, clock.now < timeout {
            await Task.yield()
        }
        guard !parked.isEmpty else {
            Issue.record("timed out waiting for a test deadline to be armed")
            return
        }
        fireDeadlines()
    }

    private func cancelParked(_ id: UUID) {
        parked.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
