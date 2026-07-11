import Foundation

/// Builds ordered reconciliation steps without performing I/O.
public struct ResyncPlan: Codable, Hashable, Sendable {
    /// The ordered reconciliation steps.
    public let steps: [ResyncPlanStep]

    /// Creates a resync plan.
    /// - Parameter steps: Ordered reconciliation steps.
    public init(steps: [ResyncPlanStep]) {
        self.steps = steps
    }

    /// Computes the resync plan for a hello handshake.
    /// - Parameters:
    ///   - cachedEpoch: The cached epoch, if any.
    ///   - helloEpoch: The epoch reported by the Mac hello.
    ///   - openConversations: Open conversations that may need tail pages.
    ///   - ticketQueue: Tickets retained across reconnects and epoch changes.
    /// - Returns: An ordered pure resync plan.
    public static func make(
        cachedEpoch: ReplicaEpoch?,
        helloEpoch: ReplicaEpoch,
        openConversations: [ResyncConversationState],
        ticketQueue: [SendTicket]
    ) -> ResyncPlan {
        var steps: [ResyncPlanStep] = []
        let epochChanged = cachedEpoch != nil && cachedEpoch != helloEpoch
        steps.append(epochChanged ? .dropAll : .keepState)
        steps.append(.pullSessions)

        let conversationsToPull: [ResyncConversationState]
        if epochChanged {
            conversationsToPull = openConversations
        } else {
            conversationsToPull = openConversations.filter(\.needsTailPull)
        }
        for conversation in conversationsToPull.sorted(by: { $0.sessionID.rawValue < $1.sessionID.rawValue }) {
            steps.append(.pullTailPage(conversation.sessionID))
        }
        if !ticketQueue.isEmpty {
            steps.append(.flushTickets)
        }
        return ResyncPlan(steps: steps)
    }
}
