import Foundation
@testable import CmuxSimulatorWorker

final class ImmediateWheelSleeper: SimulatorHIDSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [Duration] = []

    var durations: [Duration] { lock.withLock { recordedDurations } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { recordedDurations.append(duration) }
    }
}
