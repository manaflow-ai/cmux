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
}
