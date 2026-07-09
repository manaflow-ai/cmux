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
        let responderID = memoryPressureResponderID
        let severity = snapshot.severity
        let result = controller.reclaimForSystemMemoryPressure(
            now: snapshot.sampledAt
        ) { retryResult, performedAt in
            MemoryPressureResponderRegistry.logShedAction(
                MemoryPressureShedAction(
                    responderID: responderID,
                    severity: severity,
                    reclaimedItemCount: retryResult.reclaimedCount,
                    estimatedBytes: nil,
                    detail: retryResult.detail(prefix: "hidden-terminal-renderers-retry"),
                    performedAt: performedAt
                )
            )
        }
        return MemoryPressureShedResult(
            reclaimedItemCount: result.reclaimedCount,
            detail: result.detail(prefix: "hidden-terminal-renderers")
        )
    }
}
