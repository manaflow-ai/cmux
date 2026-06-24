#if canImport(UIKit)
import CmuxMobileDiagnostics
import Dispatch
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    nonisolated static func makeGhosttyRenderWorkItem(
        token: GhosttyRenderCancellationToken,
        surfaceHandle: GhosttySurfaceWorkHandle,
        executor: GhosttySurfaceWorkExecutor,
        generation: UInt64,
        enqueuedAt: CFTimeInterval,
        beginExecution: @escaping @MainActor @Sendable (UInt64, GhosttyRenderCancellationToken, CFTimeInterval) -> Bool,
        completion: @escaping @MainActor @Sendable (UInt64, GhosttyRenderCancellationToken) -> Void
    ) -> GhosttyRenderWorkItem {
        let dispatchWorkItem = DispatchWorkItem {
            let lagMs = (CACurrentMediaTime() - enqueuedAt) * 1000
            if lagMs > 150 { MobileDebugLog.anchormux("oq.render.LAG \(Int(lagMs))ms") }
            Task { @MainActor in
                let startedAt = CACurrentMediaTime()
                guard beginExecution(generation, token, startedAt) else { return }
                executor.async {
                    ghostty_surface_render_now(surfaceHandle.surface)
                    Task { @MainActor in
                        completion(generation, token)
                    }
                }
            }
        }
        return GhosttyRenderWorkItem(token: token, dispatchWorkItem: dispatchWorkItem)
    }

    func cancelRenderWorkItem(generation: UInt64) {
        guard let workItem = renderWorkItemsByGeneration.removeValue(forKey: generation) else { return }
        workItem.dispatchWorkItem.cancel()
    }

    func clearRenderWorkItem(generation: UInt64) {
        renderWorkItemsByGeneration.removeValue(forKey: generation)
    }

    func cancelAllRenderWorkItems() {
        for workItem in renderWorkItemsByGeneration.values {
            workItem.dispatchWorkItem.cancel()
        }
        renderWorkItemsByGeneration.removeAll()
    }
}
#endif
