import Foundation

struct CloudOperationSnapshot: Identifiable, Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let id: String
        let phase: CloudOperationPhase
        let startedAt: Date
        var outcome: CloudTelemetrySpan.Outcome?
        var durationMs: Int64?
        var failure: CloudDiagnosticFailure?
        var isRemote = false
    }
    let id: UUID
    let traceID: String
    let operation: CloudOperationKind
    let startedAt: Date
    var foreground: Bool
    var steps: [Step]
    var outcome: CloudTelemetrySpan.Outcome?
    var failure: CloudDiagnosticFailure?
    var isRunning: Bool { outcome == nil || steps.contains { $0.outcome == nil && !$0.isRemote } }
    var needsAttention: Bool { outcome == .failure || outcome == .timeout || steps.contains { $0.phase == .ready && ($0.outcome == .failure || $0.outcome == .timeout) } }
    var currentPhase: CloudOperationPhase { steps.last(where: { $0.outcome == nil })?.phase ?? steps.last?.phase ?? .operation }
    var reference: String { "operation=\(id.uuidString.lowercased()) trace=\(traceID)" }
    var isVisibleInMachinesPanel: Bool { foreground && (isRunning || needsAttention) }
    var copyableError: String { CloudDiagnosticReport.operationText(self) }
}
