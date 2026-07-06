#if os(iOS)
import Foundation
import GhosttyKit
import QuartzCore

extension GhosttySurfaceView {
    func requestLiveSnapshotFallbackIfNeeded() {
        guard pendingSnapshotFallbackRead == nil,
              let surface,
              !isDismantled,
              !renderPipelineRecoveryPaused,
              !renderingSuspended else {
            return
        }
        let generation = surfaceGeneration
        let operationID = makeSurfaceOperationID()
        pendingSnapshotFallbackRead = PendingSnapshotFallbackRead(
            id: operationID,
            startedAt: CACurrentMediaTime()
        )
        ensureSurfaceOperationDeadlinePump()
        let read = SnapshotFallbackRead(surface: surface, generation: generation)
        outputQueue.async {
            let snapshot = Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_VIEWPORT)
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingSnapshotFallbackRead?.id == operationID else { return }
                self.pendingSnapshotFallbackRead = nil
                guard self.surface == read.surface,
                      self.surfaceGeneration == read.generation,
                      !self.surfaceHasReceivedOutput,
                      let snapshot else {
                    return
                }
                _ = self.updateSnapshotFallback(text: snapshot, html: nil, clearWhenEmpty: true)
            }
        }
    }
}

nonisolated struct PendingSnapshotFallbackRead {
    let id: UInt64
    let startedAt: CFTimeInterval
    var timedOut = false
}

nonisolated private struct SnapshotFallbackRead: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
}
#endif
