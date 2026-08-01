import Foundation
@testable import CmuxSimulatorUIAutomation

// The lock serializes every read and mutation of the two integer fields.
final class AdvancingSimulatorUIAutomationTiming:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentMilliseconds: Int64
    private var recordedSleepCount = 0

    init(nowMilliseconds: Int64) {
        currentMilliseconds = nowMilliseconds
    }

    var sleepCount: Int {
        lock.withLock { recordedSleepCount }
    }

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock {
            currentMilliseconds += milliseconds
            recordedSleepCount += 1
        }
    }
}
