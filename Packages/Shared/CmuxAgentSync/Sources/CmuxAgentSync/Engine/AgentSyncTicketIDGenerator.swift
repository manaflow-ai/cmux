public import Foundation

/// Mints stable client-side send-ticket identifiers.
public protocol AgentSyncTicketIDGenerator: Sendable {
    /// Creates the next ticket UUID.
    /// - Returns: A stable UUID for one send ticket.
    func nextTicketID() -> UUID
}
