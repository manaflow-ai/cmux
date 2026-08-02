import Foundation
@testable import CmuxSimulatorUIAutomation

final class AdvancingActionScheduler:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nowMilliseconds: Int64

    init(nowMilliseconds: Int64) {
        self.nowMilliseconds = nowMilliseconds
    }

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { nowMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { nowMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock { nowMilliseconds += milliseconds }
    }
}
