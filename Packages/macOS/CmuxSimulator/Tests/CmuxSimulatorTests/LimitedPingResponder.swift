import Foundation
@testable import CmuxSimulator

/// The lock protects the acknowledgement counter accessed by concurrent test
/// endpoint callbacks, which is the safety argument for unchecked Sendable.
final class LimitedPingResponder: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumAcknowledgements: Int
    private var acknowledgementCount = 0
    private var acknowledgementsEnabled = true

    init(maximumAcknowledgements: Int) {
        self.maximumAcknowledgements = maximumAcknowledgements
    }

    func response(to message: SimulatorWorkerInbound) -> SimulatorWorkerOutbound? {
        guard case let .ping(sequence) = message else { return nil }
        return lock.withLock {
            guard acknowledgementsEnabled,
                  acknowledgementCount < maximumAcknowledgements else { return nil }
            acknowledgementCount += 1
            return .ack(sequence)
        }
    }

    func stopAcknowledging() {
        lock.withLock { acknowledgementsEnabled = false }
    }
}
