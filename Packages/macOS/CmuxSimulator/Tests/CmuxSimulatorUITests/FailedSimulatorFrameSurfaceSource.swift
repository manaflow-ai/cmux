import Foundation
@testable import CmuxSimulatorUI

final class FailedSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    func hasFailed() -> Bool {
        true
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        _ = sequence
        return false
    }

    func copyLatestFrame(
        after sequence: UInt64?
    ) async -> SimulatorFrameSnapshot? {
        _ = sequence
        return nil
    }
}
