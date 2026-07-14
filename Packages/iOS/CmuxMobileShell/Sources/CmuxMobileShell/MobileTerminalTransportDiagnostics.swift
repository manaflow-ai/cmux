#if DEBUG
import Foundation

/// DEBUG-only snapshot of the selected terminal's transport owners.
/// Every depth is read from the same per-surface collection that controls the
/// corresponding delivery, replay, or acknowledgement lifecycle.
public struct MobileTerminalTransportDiagnosticsSnapshot: Equatable, Sendable {
    /// Number of terminal output deliveries waiting in the selected surface's queue.
    public let deliveryQueueDepth: Int
    /// Whether the selected surface currently owns a replay barrier token.
    public let replayBarrierDepth: Int
    /// Whether a replay request for the selected surface is currently in flight.
    public let replayInFlightDepth: Int
    /// Whether the selected surface is waiting for a viewport acknowledgement.
    public let pendingViewportAckDepth: Int
    /// Highest terminal byte sequence delivered to the selected surface.
    public let deliveredEndSeq: UInt64
}

extension MobileShellComposite {
    /// Reads the selected terminal's live delivery and replay lifecycle state.
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
