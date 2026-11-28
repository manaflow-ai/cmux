import Foundation

public struct CloudOperationSnapshot: Identifiable, Equatable, Sendable {
    public struct Step: Identifiable, Equatable, Sendable {
        public let id: String
        public let phase: CloudOperationPhase
        public let startedAt: Date
        public var outcome: CloudTelemetrySpan.Outcome?
        public var durationMs: Int64?
        public var failure: CloudDiagnosticFailure?
        public var isRemote = false

        public init(
            id: String,
            phase: CloudOperationPhase,
            startedAt: Date,
            outcome: CloudTelemetrySpan.Outcome? = nil,
            durationMs: Int64? = nil,
            failure: CloudDiagnosticFailure? = nil,
            isRemote: Bool = false
        ) {
            self.id = id
            self.phase = phase
            self.startedAt = startedAt
            self.outcome = outcome
            self.durationMs = durationMs
            self.failure = failure
            self.isRemote = isRemote
        }
    }
    public let id: UUID
    public let traceID: String
    public let operation: CloudOperationKind
    public let startedAt: Date
    /// Wall-clock duration of the logical operation, including all recorded steps.
    public var durationMs: Int64? = nil
    public var foreground: Bool
    public var steps: [Step]
    public var outcome: CloudTelemetrySpan.Outcome?
    public var failure: CloudDiagnosticFailure?
    public var isRunning: Bool { outcome == nil || steps.contains { $0.outcome == nil && !$0.isRemote } }
    public var needsAttention: Bool { outcome == .failure || outcome == .timeout || steps.contains { $0.phase == .ready && ($0.outcome == .failure || $0.outcome == .timeout) } }
    var currentPhase: CloudOperationPhase { steps.last(where: { $0.outcome == nil })?.phase ?? steps.last?.phase ?? .operation }
    public var reference: String { "operation=\(id.uuidString.lowercased()) trace=\(traceID)" }
    public var isVisibleInMachinesPanel: Bool { foreground && (isRunning || needsAttention) }
    public var copyableError: String { CloudDiagnosticReport.operationText(self) }
}
