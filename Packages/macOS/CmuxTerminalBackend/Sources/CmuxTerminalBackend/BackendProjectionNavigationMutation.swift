public import Foundation

/// One claimed logical window's member of an atomic v2 mutation batch.
public struct BackendProjectionNavigationMutation: Codable, Equatable, Sendable {
    /// The stable logical-window identifier.
    public let logicalPresentationID: UUID

    /// The exact claim issued to this live connection.
    public let claimID: UUID

    /// The record generation the caller observed.
    public let expectedGeneration: UInt64

    /// Ordered navigation operations applied atomically to this record.
    public let operations: [BackendProjectionNavigationOperation]

    /// Creates one projection mutation.
    ///
    /// - Parameters:
    ///   - logicalPresentationID: The stable logical-window identifier.
    ///   - claimID: The exact connection-owned claim.
    ///   - expectedGeneration: The record generation the caller observed.
    ///   - operations: Ordered operations applied atomically.
    public init(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        operations: [BackendProjectionNavigationOperation]
    ) {
        self.logicalPresentationID = logicalPresentationID
        self.claimID = claimID
        self.expectedGeneration = expectedGeneration
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case logicalPresentationID = "logical_presentation_id"
        case claimID = "claim_id"
        case expectedGeneration = "expected_generation"
        case operations
    }
}
