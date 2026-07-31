public import Foundation

/// Client-incarnation and ordered generations carried by an initial control stream.
///
/// The server retains a high-water mark for this token so a cancelled,
/// cancellation-ignoring predecessor cannot replace a newer admitted connection.
public struct CmxIrohConnectionAttempt: Equatable, Hashable, Sendable {
    /// Random identity shared by every runtime created in one client process.
    public let processIncarnation: UUID

    /// Nonzero runtime generation within the process incarnation.
    public let engineGeneration: UInt64

    /// Nonzero monotonic generation for one peer within the engine generation.
    public let dialGeneration: UInt64
    /// Optional positive process-local trace ID. This is deliberately unrelated
    /// to the stable process incarnation, peer identity, route, or credential.
    public let diagnosticCorrelationID: Int?

    /// Creates a validated attempt token.
    public init(
        processIncarnation: UUID,
        engineGeneration: UInt64,
        dialGeneration: UInt64,
        diagnosticCorrelationID: Int? = nil
    ) {
        precondition(engineGeneration > 0)
        precondition(dialGeneration > 0)
        precondition(diagnosticCorrelationID.map { $0 > 0 } ?? true)
        self.processIncarnation = processIncarnation
        self.engineGeneration = engineGeneration
        self.dialGeneration = dialGeneration
        self.diagnosticCorrelationID = diagnosticCorrelationID
    }
}
