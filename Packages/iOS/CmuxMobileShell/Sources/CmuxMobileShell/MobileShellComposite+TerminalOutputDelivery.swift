import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        guard !expectsRenderGridTerminalOutput else {
            MobileDebugLog.anchormux(
                "sync.raw_bytes.dropped surface=\(surfaceID) reason=render_grid_transport bytes=\(bytes.count)"
            )
            return
        }
        deliverTerminalOutput(
            TerminalOutputDelivery(bytes: bytes, replaceable: false),
            surfaceID: surfaceID
        )
    }

    func deliverTerminalRenderGrid(
        _ envelope: MobileTerminalRenderGridEnvelope,
        surfaceID: String
    ) {
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: envelope,
                replaceable: false
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
