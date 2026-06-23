import CMUXMobileCore
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String, endSeq: UInt64? = nil) {
        deliverTerminalOutput(
            TerminalOutputDelivery(bytes: bytes, replaceable: false, endSeq: endSeq),
            surfaceID: surfaceID
        )
    }

    func deliverTerminalRenderGrid(_ frame: MobileTerminalRenderGridFrame, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: frame.isReplaceableViewportPatchForMobileDelivery
            ),
            surfaceID: surfaceID
        )
    }

    private func deliverTerminalOutput(_ delivery: TerminalOutputDelivery, surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        markTerminalBytesQueued(surfaceID: surfaceID, endSeq: delivery.endSeq)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            continuation.yield(
                MobileTerminalOutputChunk(data: immediate.bytes, streamToken: streamToken)
            )
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        if let endSeq = queue.inFlightEndSeq {
            markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
        }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(data: next.bytes, streamToken: streamToken))
    }

    /// Mark the current yielded terminal-output chunk as abandoned before it reached the iOS surface.
    ///
    /// This clears queued backpressure and rolls accepted sequence state back
    /// to the last applied chunk, so a rebuilt surface waits for authoritative
    /// replay instead of acknowledging bytes it never rendered.
    public func terminalOutputDidDropForRetry(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        queue.reset()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        queuedTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
    }
}
