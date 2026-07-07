import Foundation
import OSLog

@MainActor
final class MemoryPressureResponderRegistry {
    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "MemoryPressure"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.cmuxterm.app",
        category: "MemoryPressure"
    )

    private var respondersByID: [String: any MemoryPressureResponder] = [:]

    func register(_ responder: any MemoryPressureResponder) {
        respondersByID[responder.memoryPressureResponderID] = responder
    }

    @discardableResult
    func dispatch(_ snapshot: MemoryPressureSnapshot) -> [MemoryPressureShedAction] {
        guard snapshot.severity >= .warning else { return [] }

        let eligibleResponders = respondersByID.values
            .filter { snapshot.severity >= $0.memoryPressureMinimumSeverity }
            .sorted { lhs, rhs in
                if lhs.memoryPressurePriority != rhs.memoryPressurePriority {
                    return lhs.memoryPressurePriority > rhs.memoryPressurePriority
                }
                if lhs.memoryPressureMinimumSeverity != rhs.memoryPressureMinimumSeverity {
                    return lhs.memoryPressureMinimumSeverity > rhs.memoryPressureMinimumSeverity
                }
                return lhs.memoryPressureResponderID < rhs.memoryPressureResponderID
            }

        return eligibleResponders.map { responder in
            let result = responder.shedMemory(for: snapshot)
            let action = MemoryPressureShedAction(
                responderID: responder.memoryPressureResponderID,
                severity: snapshot.severity,
                reclaimedItemCount: result.reclaimedItemCount,
                estimatedBytes: result.estimatedBytes,
                detail: result.detail,
                performedAt: snapshot.sampledAt
            )
            logShedAction(action)
            return action
        }
    }

    private func logShedAction(_ action: MemoryPressureShedAction) {
        let estimatedBytes = action.estimatedBytes.map(String.init) ?? "unknown"
        let detail = action.detail ?? "none"
        Self.logger.info(
            "memoryPressure.shed responder=\(action.responderID, privacy: .public) severity=\(action.severity.logName, privacy: .public) reclaimedItems=\(action.reclaimedItemCount, privacy: .public) estimatedBytes=\(estimatedBytes, privacy: .public) detail=\(detail, privacy: .public)"
        )
        let signpostID = Self.signposter.makeSignpostID()
        Self.signposter.emitEvent(
            "MemoryPressureShed",
            id: signpostID,
            "responder=\(action.responderID) severity=\(action.severity.logName) reclaimedItems=\(action.reclaimedItemCount)"
        )
    }
}
