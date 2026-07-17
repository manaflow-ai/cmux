import Foundation
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
        // `sleep(for:)` reaches the actor. Yield until that real signal is registered instead of
        // adding timing sleeps to the test.
        while parked.isEmpty {
            await Task.yield()
        }
        fireDeadlines()
    }

    private func cancelParked(_ id: UUID) {
        parked.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
