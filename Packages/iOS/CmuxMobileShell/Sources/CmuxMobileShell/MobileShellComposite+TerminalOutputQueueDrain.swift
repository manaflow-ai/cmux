internal import CmuxMobileDiagnostics
import Foundation

extension MobileShellComposite {
    func terminalOutputAfterDroppingStaleQueuedFrames(
        from queue: inout TerminalOutputDeliveryQueue,
        surfaceID: String
    ) -> TerminalOutputDelivery? {
        var next = queue.completeInFlight()
        while let candidate = next,
              shouldDropQueuedTerminalOutput(candidate, surfaceID: surfaceID) {
            next = queue.completeInFlight()
        }
        return next
    }

    func prepareQueuedReplayBarrierAckIfNeeded(
        for delivery: TerminalOutputDelivery,
        surfaceID: String,
        streamToken: UUID
    ) {
        guard let replayBarrierToken = delivery.replayBarrierAckToken,
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return
        }
        terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] = streamToken
    }

    private func shouldDropQueuedTerminalOutput(
        _ delivery: TerminalOutputDelivery,
        surfaceID: String
    ) -> Bool {
        guard let renderGrid = delivery.renderGridFrame else { return false }
        let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        let preBarrierFloorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID]
        let deliveredFloor = max(deliveredSeq, preBarrierFloorSeq ?? 0)
        let isStale = deliveredSeq > renderGrid.stateSeq
            || (preBarrierFloorSeq.map { $0 >= renderGrid.stateSeq } ?? false)
        guard isStale else { return false }
        if let replayBarrierToken = delivery.replayBarrierAckToken {
            consumeTerminalReplayFailureRetryAfterNoProgress(
                surfaceID: surfaceID,
                reason: "stale_queued_render_grid"
            )
            clearTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: replayBarrierToken,
                reason: "stale_queued_render_grid"
            )
        }
        MobileDebugLog.anchormux(
            "terminal.output.drop_stale_queued_render_grid surface=\(surfaceID) delivered=\(deliveredFloor) frame=\(renderGrid.stateSeq)"
        )
        return true
    }
}
