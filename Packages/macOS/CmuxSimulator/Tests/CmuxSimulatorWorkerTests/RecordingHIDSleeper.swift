import Foundation
@testable import CmuxSimulatorWorker

final class RecordingHIDSleeper: SimulatorHIDSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private let throwOnCall: Int?
    private var recordedDurations: [Duration] = []

    init(throwOnCall: Int? = nil) {
        self.throwOnCall = throwOnCall
    }

    var durations: [Duration] {
        lock.withLock { recordedDurations }
    }

    func sleep(for duration: Duration) async throws {
        let call = lock.withLock { () -> Int in
            recordedDurations.append(duration)
            return recordedDurations.count
        }
        if call == throwOnCall { throw CancellationError() }
    }
}
