import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Drop legacy raw PTY byte chunks before they can switch an iOS terminal
    /// surface away from the render-grid display model.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        MobileDebugLog.anchormux(
            "sync.raw_bytes.dropped surface=\(surfaceID) reason=render_grid_only bytes=\(bytes.count)"
        )
    }

    func deliverTerminalRenderGrid(
        _ envelope: MobileTerminalRenderGridEnvelope,
        surfaceID: String
    ) {
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: envelope,
                replaceable: envelope.isReplaceableVisualUpdate
            ),
            surfaceID: surfaceID
        )
    }

    private func deliverTerminalOutput(_ delivery: TerminalOutputDelivery, surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        let renderGridOverflowSeq = queue.consumeRenderGridOverflowStateSeq()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let renderGridOverflowSeq {
            handleTerminalOutputQueueRenderGridOverflow(
                surfaceID: surfaceID,
                stateSeq: renderGridOverflowSeq
            )
        }
        if let immediate {
            continuation.yield(immediate.chunk(streamToken: streamToken))
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(next.chunk(streamToken: streamToken))
    }
}
