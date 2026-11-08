public import Foundation
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
        onApplied: @escaping @MainActor @Sendable () -> Void,
        onDiscarded: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        guard !data.isEmpty else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "remoteReplay") else {
            // A completion is sound only while the entire replacement remains
            // in the bounded pre-runtime buffer. If appending would evict its
            // leading bytes, leave fidelity unconfirmed so the owner can
            // refetch rather than claiming a truncated replay was applied.
            if data.count <= maxPendingRemoteOutputBytes - pendingRemoteOutput.count {
                pendingRemoteReplayCompletions.append(
                    TerminalSurfacePendingRemoteReplayCompletion(
                        applied: onApplied, discarded: onDiscarded
                    )
                )
            } else {
                discardPendingRemoteReplayCompletions()
                onDiscarded()
            }
            processRemoteOutput(data)
            return
        }
        flushPendingRemoteOutput(to: surface)
        remoteOutputLane.enqueue(data, to: surface, onApplied: onApplied)
    }
}
