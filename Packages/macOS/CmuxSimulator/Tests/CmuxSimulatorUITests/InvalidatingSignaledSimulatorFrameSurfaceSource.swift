import Foundation
@testable import CmuxSimulatorUI

final class InvalidatingSignaledSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var publicationHandler: (@Sendable () -> Void)?
    private var copies = 0
    private var copyStarted = false
    private var copyIsBlocked = true
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var copyCount: Int {
        lock.withLock { copies }
    }

    var hasStartedCopy: Bool {
        lock.withLock { copyStarted }
    }

    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool {
        lock.withLock { publicationHandler = handler }
        return true
    }

    func publish(_ snapshot: SimulatorFrameSnapshot) {
        let handler = lock.withLock {
            self.snapshot = snapshot
            return publicationHandler
        }
        handler?()
    }

    func releaseCopy() {
        let waiters = lock.withLock {
            copyIsBlocked = false
            let waiters = copyWaiters
            copyWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        let copiedSequence = lock.withLock {
            copies += 1
            copyStarted = true
            return snapshot.sequence
        }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard copyIsBlocked else { return true }
                copyWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
        return lock.withLock {
            guard snapshot.sequence == copiedSequence,
                  sequence.map({ copiedSequence > $0 }) ?? true else {
                return nil
            }
            return snapshot
        }
    }
}
