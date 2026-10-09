/// One auditable result of semantic notification reconciliation.
public struct AgentNotificationDecision: Sendable, Equatable {
    /// Why a candidate is accepted, delayed, or dropped.
    public enum Disposition: String, Sendable {
        /// A meaningful attention boundary is ready for durable admission.
        case accepted
        /// Work remains; a later settled event may still be accepted.
        case delayed
        /// A newer lifecycle event already governs this session.
        case stale
        /// The event has no trustworthy session/surface binding.
        case unattributed
        /// A nested agent cannot notify as the parent.
        case subagent
        /// An observation or lifecycle update has no notification effects.
        case observation
    }
    /// Result of the reconciliation.
    public let disposition: Disposition
    /// Stable semantic identity; independent of workspace moves and presentation text.
    public let identity: String?

    /// Previously accepted requests invalidated by an explicit continuation or end.
    public let invalidatedCorrelationKeys: [String]

    /// A previously delayed completion released by a causal child/request resolution.
    public let notificationEvent: AgentJournalEvent?

    /// Whether the event contributed a lifecycle assertion rather than only a reminder.
    public let projectsLifecycle: Bool

    init(_ disposition: Disposition, identity: String? = nil, invalidatedCorrelationKeys: [String] = [], notificationEvent: AgentJournalEvent? = nil, projectsLifecycle: Bool = true) {
        self.disposition = disposition
        self.identity = identity
        self.invalidatedCorrelationKeys = invalidatedCorrelationKeys
        self.notificationEvent = notificationEvent
        self.projectsLifecycle = projectsLifecycle
    }
}
