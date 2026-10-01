/// One row of a conversation's timeline.
public struct ConversationItem: Hashable, Sendable, Identifiable {
    /// What a row shows.
    public enum Kind: Hashable, Sendable {
        /// Text from the user or the agent.
        case message(ConversationMessage)
        /// The agent's visible reasoning.
        case reasoning(String)
        /// A tool call or other work, updated as it runs.
        case activity(ActivityItem)
        /// The agent's current plan.
        case plan([PlanEntry])
        /// A request for the user's approval or answer.
        case approval(ApprovalRequest)
        /// A short status line (a failover, a resumed session).
        case notice(String)
        /// An error the turn reported.
        case error(String)
        /// A turn finished; `stopReason` is the backend's reason.
        case turnEnded(stopReason: String?)
        /// A backend-specific item.
        case `extension`(ExtensionItem)
    }

    /// Stable identity across updates, merges and reloads.
    public let id: String
    /// What the row shows.
    public var kind: Kind
    /// When the backend recorded it, in milliseconds since 1970, if known.
    public var timestamp: UInt64?

    /// Creates a row.
    /// - Parameters:
    ///   - id: Stable identity.
    ///   - kind: What it shows.
    ///   - timestamp: Recording time in milliseconds since 1970.
    public init(id: String, kind: Kind, timestamp: UInt64? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}
