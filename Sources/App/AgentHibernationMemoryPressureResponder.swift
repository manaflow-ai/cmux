import Foundation

@MainActor
final class AgentHibernationMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "idle-agent-hibernation"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .critical
    let memoryPressurePriority = 80

    private let controller: AgentHibernationController

    init(controller: AgentHibernationController) {
        self.controller = controller
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let responderID = memoryPressureResponderID
        let severity = snapshot.severity
        let didSchedule = controller.reclaimIdleAgentsForSystemMemoryPressure(
            now: snapshot.sampledAt
        ) { hibernatedCount in
            guard hibernatedCount > 0 else { return }
            MemoryPressureResponderRegistry.logShedAction(
                MemoryPressureShedAction(
                    responderID: responderID,
                    severity: severity,
                    reclaimedItemCount: hibernatedCount,
                    estimatedBytes: nil,
                    detail: "hidden-idle-agents",
                    performedAt: .now
                )
            )
        }
        return MemoryPressureShedResult(
            reclaimedItemCount: 0,
            detail: didSchedule
                ? "hidden-idle-agent-evaluation"
                : "hidden-idle-agent-evaluation-in-flight"
        )
    }
}
