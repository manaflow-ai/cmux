import Foundation

/// Applies FIFO send-ticket updates with legal transition enforcement.
public struct TicketLedgerClient: Codable, Hashable, Sendable {
    /// Tickets in FIFO order.
    public private(set) var tickets: [SendTicket]
    /// Count of illegal transition attempts that were dropped.
    public private(set) var illegalTransitionCount: Int

    /// Creates a ticket ledger.
    /// - Parameters:
    ///   - tickets: Initial FIFO tickets.
    ///   - illegalTransitionCount: Initial illegal transition count.
    public init(tickets: [SendTicket] = [], illegalTransitionCount: Int = 0) {
        self.tickets = tickets.sorted { $0.createdAt < $1.createdAt }
        self.illegalTransitionCount = illegalTransitionCount
    }

    /// Applies a ticket update if it is legal.
    /// - Parameter ticket: The incoming ticket update.
    /// - Returns: Whether the ledger changed.
    @discardableResult
    public mutating func apply(_ ticket: SendTicket) -> Bool {
        guard let index = updateIndex(for: ticket) else {
            tickets.append(ticket)
            tickets.sort { $0.createdAt < $1.createdAt }
            return true
        }

        let current = tickets[index]
        guard isLegalTransition(from: current.state, to: ticket.state) else {
            illegalTransitionCount += 1
            return false
        }

        tickets[index] = ticket
        tickets.sort { $0.createdAt < $1.createdAt }
        return true
    }

    /// Tests whether a state transition is legal.
    /// - Parameters:
    ///   - current: The current ticket state.
    ///   - next: The proposed ticket state.
    /// - Returns: Whether the transition may be applied.
    public func isLegalTransition(from current: SendTicketState, to next: SendTicketState) -> Bool {
        if current == next {
            return true
        }
        return switch (current, next) {
        case (.queuedLocal, .acceptedByMac),
             (.queuedLocal, .injected),
             (.queuedLocal, .echoed),
             (.queuedLocal, .failed),
             (.queuedLocal, .unconfirmed),
             (.acceptedByMac, .injected),
             (.acceptedByMac, .echoed),
             (.acceptedByMac, .failed),
             (.acceptedByMac, .unconfirmed),
             (.injected, .echoed),
             (.injected, .failed),
             (.injected, .unconfirmed),
             (.unconfirmed, .acceptedByMac),
             (.unconfirmed, .injected),
             (.unconfirmed, .echoed),
             (.unconfirmed, .failed):
            true
        default:
            false
        }
    }

    private func updateIndex(for ticket: SendTicket) -> Int? {
        if case .echoed = ticket.state {
            if let unresolvedIndex = tickets.firstIndex(where: { existing in
                existing.id == ticket.id && !existing.state.isResolved
            }) {
                return unresolvedIndex
            }
        }
        return tickets.firstIndex { $0.id == ticket.id }
    }
}
