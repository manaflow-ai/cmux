#if canImport(UIKit)
import UIKit

extension GhosttySurfaceView {
    func cancelRenderWorkItem(generation: UInt64) {
        renderWorkItemsByGeneration.removeValue(forKey: generation)?.cancel()
    }

    func clearRenderWorkItem(generation: UInt64) {
        renderWorkItemsByGeneration.removeValue(forKey: generation)
    }

    func cancelAllRenderWorkItems() {
        for workItem in renderWorkItemsByGeneration.values {
            workItem.cancel()
        }
        renderWorkItemsByGeneration.removeAll()
    }
}
#endif
