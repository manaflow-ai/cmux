@testable import CmuxSimulatorUI

actor BlockingSimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading {
    private var latestSnapshot: SimulatorFrameSnapshot
    private var blocked = true
    private var started = false
    private var copies = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: SimulatorFrameSnapshot) {
        latestSnapshot = snapshot
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        let snapshot = latestSnapshot
        guard sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
        copies += 1
        started = true
        if blocked {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return snapshot
    }

    func update(snapshot: SimulatorFrameSnapshot) {
        latestSnapshot = snapshot
    }

    func release() {
        blocked = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func hasStarted() -> Bool { started }

    func copyCount() -> Int { copies }
}
