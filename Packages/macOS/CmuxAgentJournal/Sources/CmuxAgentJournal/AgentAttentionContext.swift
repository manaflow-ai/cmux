/// Provider-independent causal evidence, shared by hooks and feed adapters.
public struct AgentAttentionContext: Codable, Sendable, Equatable {
    /// Stable native event identity, when supplied by the provider.
    public var eventIdentity: String?
    /// Native turn identity; a late completion cannot settle a different turn.
    public var turnIdentity: String?
    /// Native approval/tool-call identity, shared across delivery transports.
    public var requestIdentity: String?
    /// A notification candidate; lifecycle-only observations omit this value.
    public var notification: AgentJournalNotification?

    /// Creates causal evidence without inferring identity from presentation text.
    /// - Parameters:
    ///   - eventIdentity: Stable native event identifier.
    ///   - turnIdentity: Native turn identifier.
    ///   - requestIdentity: Native request or tool-call identifier.
    ///   - notification: Optional notification candidate.
    public init(eventIdentity: String? = nil, turnIdentity: String? = nil,
                requestIdentity: String? = nil, notification: AgentJournalNotification? = nil) {
        self.eventIdentity = eventIdentity
        self.turnIdentity = turnIdentity
        self.requestIdentity = requestIdentity
        self.notification = notification
    }
}
