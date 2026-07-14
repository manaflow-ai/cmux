#if canImport(UIKit) && DEBUG
import CmuxMobileShell

nonisolated struct MobileTerminalDiagnosticsTransportValue: Equatable {
    let deliveryQueueDepth: Int
    let replayBarrierDepth: Int
    let replayInFlightDepth: Int
    let pendingViewportAckDepth: Int
    let deliveredEndSeq: UInt64

    init(_ snapshot: MobileTerminalTransportDiagnosticsSnapshot) {
        deliveryQueueDepth = snapshot.deliveryQueueDepth
        replayBarrierDepth = snapshot.replayBarrierDepth
        replayInFlightDepth = snapshot.replayInFlightDepth
        pendingViewportAckDepth = snapshot.pendingViewportAckDepth
        deliveredEndSeq = snapshot.deliveredEndSeq
    }

    init(
        deliveryQueueDepth: Int,
        replayBarrierDepth: Int,
        replayInFlightDepth: Int,
        pendingViewportAckDepth: Int,
        deliveredEndSeq: UInt64
    ) {
        self.deliveryQueueDepth = deliveryQueueDepth
        self.replayBarrierDepth = replayBarrierDepth
        self.replayInFlightDepth = replayInFlightDepth
        self.pendingViewportAckDepth = pendingViewportAckDepth
        self.deliveredEndSeq = deliveredEndSeq
    }
}
#endif
