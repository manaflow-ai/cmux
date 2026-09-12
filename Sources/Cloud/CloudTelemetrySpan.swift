import Foundation

/// The only native payload accepted by the Cloud gateway. No free-text error or terminal data.
struct CloudTelemetrySpan: Codable, Sendable, Equatable, Identifiable {
    enum Outcome: String, Codable, Sendable { case success, failure, timeout, cancelled }
    let eventId: String
    let operationId: String
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let operation: CloudOperationKind
    let phase: CloudOperationPhase
    let outcome: Outcome
    let startedAtMs: Int64
    let endedAtMs: Int64
    let attempt: Int
    let failure: CloudDiagnosticFailure?
    var httpStatus: Int?
    var errorNumber: Int?
    var droppedCount: Int?
    var sourceFile: String?
    var sourceLine: Int?
    var id: String { eventId }
}
