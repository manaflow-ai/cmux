import Foundation
import Testing
@testable import CmuxUpdater

/// Immediate for the sub-second plumbing delays; parks second-or-longer deadlines until the test
/// releases them with ``fireDeadlines()`` so watchdog time is explicit.
actor TestDeadlineClock: UpdateClock {
    private struct ParkedDeadline {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var parked: [UUID: ParkedDeadline] = [:]

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration >= .seconds(1) else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked[id] = ParkedDeadline(duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelParked(id) }
        }
    }

    func fireDeadlines() {
        let waiters = parked
        parked = [:]
        for deadline in waiters.values {
            deadline.continuation.resume()
        }
    }

    /// Releases the shortest pending deadline after `expectedCount` deadlines have registered.
    /// This lets pipeline tests distinguish the 10-second check deadline from the 25-second
    /// install watchdog without depending on wall-clock timing or task-registration order.
    func fireEarliestDeadlineWhenReady(expectedCount: Int) async {
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(2))
        while parked.count < expectedCount, clock.now < timeout {
            await Task.yield()
        }
        guard parked.count >= expectedCount else {
            Issue.record("timed out waiting for \(expectedCount) test deadlines to be armed")
            return
        }
        guard let earliest = parked.min(by: { $0.value.duration < $1.value.duration }) else {
            Issue.record("no test deadline was armed")
            return
        }
        parked.removeValue(forKey: earliest.key)?.continuation.resume()
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
        parked.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
