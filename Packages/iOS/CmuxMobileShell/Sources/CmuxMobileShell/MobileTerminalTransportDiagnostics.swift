#if DEBUG
import Foundation

/// DEBUG-only snapshot of the selected terminal's transport owners.
/// Every depth is read from the same per-surface collection that controls the
/// corresponding delivery, replay, or acknowledgement lifecycle.
public struct MobileTerminalTransportDiagnosticsSnapshot: Equatable, Sendable {
    public let deliveryQueueDepth: Int
    public let replayBarrierDepth: Int
    public let replayInFlightDepth: Int
    public let pendingViewportAckDepth: Int
    public let deliveredEndSeq: UInt64
}

extension MobileShellComposite {
    public func mobileTerminalTransportDiagnostics(
        surfaceID: String
    ) -> MobileTerminalTransportDiagnosticsSnapshot {
        MobileTerminalTransportDiagnosticsSnapshot(
            deliveryQueueDepth: terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount ?? 0,
            replayBarrierDepth: terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil ? 0 : 1,
            replayInFlightDepth: terminalReplaySurfaceIDsInFlight.contains(surfaceID) ? 1 : 0,
            pendingViewportAckDepth: terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] == nil ? 0 : 1,
            deliveredEndSeq: deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        )
    }
}
#endif
