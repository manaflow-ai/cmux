import Foundation

/// Warns about complete aggregate metrics and schedules only safe idle-agent
/// hibernation while that same aggregate pressure remains observable.
@MainActor
final class AggregateMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "aggregate-idle-agent-hibernation"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .warning
    let memoryPressurePriority = 85

    private let controller: AgentHibernationController
    private let isAggregatePressureActive: @MainActor () -> Bool
    private let onAggregatePressureWarning: @MainActor (MemoryPressureSnapshot) -> Void

    init(
        controller: AgentHibernationController,
        isAggregatePressureActive: @escaping @MainActor () -> Bool,
        onAggregatePressureWarning: @escaping @MainActor (MemoryPressureSnapshot) -> Void = { _ in }
    ) {
        self.controller = controller
        self.isAggregatePressureActive = isAggregatePressureActive
        self.onAggregatePressureWarning = onAggregatePressureWarning
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        guard let aggregate = snapshot.aggregateMemoryPressure,
              aggregate.isActionable else {
            // A partial process listing must never authorize a teardown.
            return MemoryPressureShedResult(
                reclaimedItemCount: 0,
                detail: "aggregate-metrics-unavailable"
            )
        }

        onAggregatePressureWarning(snapshot)
        let responderID = memoryPressureResponderID
        let severity = snapshot.severity
        let didSchedule = controller.reclaimIdleAgentsForMemoryPressure(
            now: snapshot.sampledAt,
            isPressureStillActive: isAggregatePressureActive
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
                ? "aggregate-idle-agent-evaluation"
                : "aggregate-idle-agent-evaluation-in-flight"
        )
    }
}
