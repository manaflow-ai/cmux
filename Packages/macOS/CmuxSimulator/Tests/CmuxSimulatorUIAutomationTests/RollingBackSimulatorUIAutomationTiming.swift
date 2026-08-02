import Foundation
@testable import CmuxSimulatorUIAutomation

// The lock serializes every read and mutation of the timing fixture's state.
final class RollingBackSimulatorUIAutomationTiming:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var monotonicMilliseconds: Int64
    private var wallTimeMilliseconds: Int64
    private var recordedSleepCount = 0

    init(nowMilliseconds: Int64) {
        monotonicMilliseconds = nowMilliseconds
        wallTimeMilliseconds = nowMilliseconds
    }

    var sleepCount: Int {
        lock.withLock { recordedSleepCount }
    }

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { monotonicMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { wallTimeMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock {
            monotonicMilliseconds += milliseconds
            wallTimeMilliseconds += milliseconds - 5_000
            recordedSleepCount += 1
        }
    }
}
