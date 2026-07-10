public import Foundation

/// Production ticket id generator backed by `UUID()`.
public struct UUIDAgentSyncTicketIDGenerator: AgentSyncTicketIDGenerator {
    /// Creates a UUID ticket generator.
    public init() {}

    /// Creates the next ticket UUID.
    /// - Returns: A fresh UUID.
    public func nextTicketID() -> UUID {
        UUID()
    }
}
