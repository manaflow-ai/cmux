import Foundation
@testable import CmuxSimulatorWorker

final class BlockingWheelIdleSleeper: SimulatorHIDSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [Duration] = []

    var durations: [Duration] { lock.withLock { recordedDurations } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { recordedDurations.append(duration) }
        if duration == .milliseconds(100) {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        }
    }
}
