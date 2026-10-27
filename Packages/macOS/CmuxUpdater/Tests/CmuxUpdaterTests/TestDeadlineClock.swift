import Foundation
import Testing
@testable import CmuxUpdater

/// One `sleep(for:tolerance:)` call the code under test made.
struct RequestedSleep: Equatable, Sendable {
    var duration: Duration
    var tolerance: Duration?
}

/// Immediate for the sub-second plumbing delays; parks second-or-longer deadlines until the test
/// releases them with ``fireDeadlines()`` so watchdog time is explicit. Records every request, so a
/// test can check the leeway and the backoff each wait asked for.
actor TestDeadlineClock: UpdateClock {
    private var parked: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Every sleep requested so far, in order.
    private(set) var requests: [RequestedSleep] = []

    func sleep(for duration: Duration, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        requests.append(RequestedSleep(duration: duration, tolerance: tolerance))
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

    func fireDeadlineWhenReady(timeout: Duration = .seconds(2)) async {
        // A test may request a deadline and immediately release it before the task running
        // `sleep(for:tolerance:)` reaches the actor. Poll that real registration signal without timing
        // sleeps, but bound the poll so a missing deadline fails instead of hanging the suite.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while parked.isEmpty, clock.now < deadline {
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
