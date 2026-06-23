import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(bytes: bytes, replaceable: false),
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
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else {
            MobileDebugLog.anchormux("tdeliver.drop surface=\(surfaceID) reason=no_sink \(delivery.debugSummary)")
            return
        }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        MobileDebugLog.anchormux(
            "tdeliver.enqueue surface=\(surfaceID) immediate=\(immediate != nil) "
            + "replaceable=\(delivery.replaceable) queue=\(queue.debugSummary) \(delivery.debugSummary)"
        )
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            MobileDebugLog.anchormux(
                "tdeliver.yield surface=\(surfaceID) token=\(streamToken.uuidString.prefix(8)) \(immediate.debugSummary)"
            )
            continuation.yield(
                MobileTerminalOutputChunk(data: immediate.bytes, streamToken: streamToken)
            )
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else {
            MobileDebugLog.anchormux(
                "tdeliver.ack.drop surface=\(surfaceID) token=\(streamToken.uuidString.prefix(8)) reason=stale_or_missing"
            )
            return
        }
        let next = queue.completeInFlight()
        MobileDebugLog.anchormux(
            "tdeliver.ack surface=\(surfaceID) token=\(streamToken.uuidString.prefix(8)) "
            + "next=\(next != nil) queue=\(queue.debugSummary)"
        )
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        MobileDebugLog.anchormux(
            "tdeliver.yield surface=\(surfaceID) token=\(streamToken.uuidString.prefix(8)) \(next.debugSummary)"
        )
        continuation.yield(MobileTerminalOutputChunk(data: next.bytes, streamToken: streamToken))
    }
}
