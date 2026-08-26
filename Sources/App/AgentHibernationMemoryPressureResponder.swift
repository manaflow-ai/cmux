import Foundation

@MainActor
final class AgentHibernationMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "idle-agent-hibernation"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .critical
    let memoryPressurePriority = 80

    private let controller: AgentHibernationController
    private let isPressureCritical: @MainActor () -> Bool

    init(
        controller: AgentHibernationController,
        isPressureCritical: @escaping @MainActor () -> Bool
    ) {
        self.controller = controller
        self.isPressureCritical = isPressureCritical
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let responderID = memoryPressureResponderID
        let severity = snapshot.severity
        let didSchedule = controller.reclaimIdleAgentsForSystemMemoryPressure(
            now: snapshot.sampledAt,
            isPressureStillCritical: isPressureCritical
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
