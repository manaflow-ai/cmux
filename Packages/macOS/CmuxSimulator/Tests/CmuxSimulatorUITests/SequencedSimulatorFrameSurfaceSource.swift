import Foundation
@testable import CmuxSimulatorUI

final class SequencedSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var copies = 0

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var copyCount: Int {
        lock.withLock { copies }
    }

    func publish(_ snapshot: SimulatorFrameSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        lock.withLock {
            guard sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
            copies += 1
            return snapshot
        }
    }
}
