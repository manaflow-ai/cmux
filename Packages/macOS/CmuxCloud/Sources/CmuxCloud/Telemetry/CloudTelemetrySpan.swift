import Foundation

/// The only native payload accepted by the Cloud gateway. No free-text error or terminal data.
public struct CloudTelemetrySpan: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case success, failure, timeout, cancelled }
    public let eventId: String
    public let operationId: String
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let operation: CloudOperationKind
    public let phase: CloudOperationPhase
    public let outcome: Outcome
    let startedAtMs: Int64
    let endedAtMs: Int64
    public let attempt: Int
    public let failure: CloudDiagnosticFailure?
    public var httpStatus: Int?
    public var errorNumber: Int?
    public var droppedCount: Int?
    var sourceFile: String?
    var sourceLine: Int?
    public var id: String { eventId }

    public init(
        eventId: String,
        operationId: String,
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        operation: CloudOperationKind,
        phase: CloudOperationPhase,
        outcome: Outcome,
        startedAtMs: Int64,
        endedAtMs: Int64,
        attempt: Int,
        failure: CloudDiagnosticFailure?,
        httpStatus: Int? = nil,
        errorNumber: Int? = nil,
        droppedCount: Int? = nil,
        sourceFile: String? = nil,
        sourceLine: Int? = nil
    ) {
        self.eventId = eventId
        self.operationId = operationId
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.operation = operation
        self.phase = phase
        self.outcome = outcome
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.attempt = attempt
        self.failure = failure
        self.httpStatus = httpStatus
        self.errorNumber = errorNumber
        self.droppedCount = droppedCount
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }
}
