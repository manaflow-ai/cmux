import Foundation
@testable import CmuxSimulatorUIAutomation

final class SequencedWallTimeActionScheduler:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let wallTimes: [Int64]
    private var wallTimeIndex = 0

    init(wallTimes: [Int64]) {
        self.wallTimes = wallTimes
    }

    func monotonicNowMilliseconds() -> Int64 { 0 }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock {
            let index = min(wallTimeIndex, wallTimes.count - 1)
            wallTimeIndex += 1
            return wallTimes[index]
        }
    }

    func nextEvent(after duration: Duration) async throws {}
}
