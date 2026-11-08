import Foundation
@testable import CmuxSimulatorUI

final class SignaledSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var publicationHandler: (@Sendable () -> Void)?
    private var availabilityChecks = 0

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var availabilityCheckCount: Int {
        lock.withLock { availabilityChecks }
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

    func signalPublicationBurst(count: Int) {
        let handler = lock.withLock { publicationHandler }
        for _ in 0..<count {
            handler?()
        }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            availabilityChecks += 1
            return sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        lock.withLock {
            guard sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
            return snapshot
        }
    }
}
