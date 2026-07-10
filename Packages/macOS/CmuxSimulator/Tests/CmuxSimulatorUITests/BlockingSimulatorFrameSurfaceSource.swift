import Foundation

@testable import CmuxSimulatorUI

final class BlockingSimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading, @unchecked Sendable {
    private let condition = NSCondition()
    private var latestSnapshot: SimulatorFrameSnapshot
    private var blocked = true
    private var started = false
    private var copies = 0

    init(snapshot: SimulatorFrameSnapshot) {
        latestSnapshot = snapshot
    }

    func copyLatestFrame(after sequence: UInt64?) -> SimulatorFrameSnapshot? {
        condition.lock()
        let snapshot = latestSnapshot
        guard sequence.map({ snapshot.sequence > $0 }) ?? true else {
            condition.unlock()
            return nil
        }
        copies += 1
        started = true
        condition.broadcast()
        while blocked { condition.wait() }
        condition.unlock()
        return snapshot
    }

    func update(snapshot: SimulatorFrameSnapshot) {
        condition.withLock { latestSnapshot = snapshot }
    }

    func release() {
        condition.lock()
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    func hasStarted() -> Bool {
        condition.withLock { started }
    }

    func copyCount() -> Int {
        condition.withLock { copies }
    }
}
