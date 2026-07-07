import Foundation

@MainActor
final class RendererRealizationMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "terminal-renderer-realization"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .warning
    let memoryPressurePriority = 100

    private let controller: RendererRealizationController

    init(controller: RendererRealizationController) {
        self.controller = controller
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let reclaimedCount = controller.reclaimForSystemMemoryPressure(now: snapshot.sampledAt)
        return MemoryPressureShedResult(
            reclaimedItemCount: reclaimedCount,
            detail: "hidden-terminal-renderers"
        )
    }
}
