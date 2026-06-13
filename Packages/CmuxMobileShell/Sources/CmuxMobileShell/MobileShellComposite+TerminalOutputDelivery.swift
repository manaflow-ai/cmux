import CMUXMobileCore
import Foundation

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
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            continuation.yield(immediate.bytes)
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String) {
        guard var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID] else {
            return
        }
        continuation.yield(next.bytes)
    }
}
