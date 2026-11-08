import Foundation
@testable import CmuxIrohTransport

/// Records retry deadlines while completing each sleep immediately.
final class RecordingImmediateHostActivationClock: CmxIrohRelayClock, @unchecked Sendable {
    private let lock = NSLock()
    private let date: Date
    private var deadlines: [Date] = []

    init(now: Date) {
        date = now
    }

    func now() -> Date {
        date
    }

    func sleep(until deadline: Date) async throws {
        lock.withLock { deadlines.append(deadline) }
    }

    func observedSleepDeadlines() -> [Date] {
        lock.withLock { deadlines }
    }
}
