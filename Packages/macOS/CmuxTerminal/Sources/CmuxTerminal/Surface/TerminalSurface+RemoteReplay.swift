import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Enqueues replacement output and refreshes after the parser has applied it.
    ///
    /// A Cloud snapshot is a replacement state, so refreshing when its bytes
    /// are merely admitted can present the previous IOSurface contents. The
    /// completion runs after the generation FIFO has parsed the bytes.
    @MainActor
    public func processRemoteReplay(
        _ data: Data,
        onApplied: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !data.isEmpty,
              let surface = liveSurfaceForGhosttyAccess(reason: "remoteReplay") else {
            processRemoteOutput(data)
            return
        }
        flushPendingRemoteOutput(to: surface)
        remoteOutputLane.enqueue(data, to: surface, onApplied: onApplied)
    }
}
