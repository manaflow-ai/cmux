import CMUXMobileCore
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
        // The first full frame a surface receives is its cold attach (ESC c +
        // scrollback seed). Every later full frame (resize, resync, divergence
        // repair) repaints the viewport in place so it never resets the scroll
        // position of a reader who is scrolled up into history.
        let coldAttach = frame.full && terminalSurfaceIDsWithFullFrame.insert(surfaceID).inserted
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: frame.isReplaceableViewportPatchForMobileDelivery,
                coldAttach: coldAttach
            ),
            surfaceID: surfaceID
        )
    }

    private func deliverTerminalOutput(_ delivery: TerminalOutputDelivery, surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            continuation.yield(
                MobileTerminalOutputChunk(
                    data: immediate.bytes,
                    streamToken: streamToken,
                    expectedGridHash: immediate.expectedGridHash
                )
            )
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
        continuation.yield(
            MobileTerminalOutputChunk(
                data: next.bytes,
                streamToken: streamToken,
                expectedGridHash: next.expectedGridHash
            )
        )
    }
}
