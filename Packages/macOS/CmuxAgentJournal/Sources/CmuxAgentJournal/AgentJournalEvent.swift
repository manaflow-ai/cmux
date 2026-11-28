/// One committed journal record: a draft plus the identity the journal
/// assigned at commit time.
///
/// `sequence` is a strictly monotonic per-journal ordinal (SQLite
/// AUTOINCREMENT, never reused); the reducer's determinism contract is defined
/// over it.
public struct AgentJournalEvent: Sendable, Equatable {
    /// Monotonic journal ordinal assigned at commit.
    public let sequence: Int64
    /// Journal wall-clock commit timestamp in ms since the Unix epoch.
    public let committedAtMs: Int64
    /// The event as the producer emitted it.
    public let draft: AgentJournalEventDraft

    /// Creates a committed record.
    ///
    /// - Parameters:
    ///   - sequence: Monotonic journal ordinal.
    ///   - committedAtMs: Commit timestamp in ms since the Unix epoch.
    ///   - draft: The producer's event.
    public init(sequence: Int64, committedAtMs: Int64, draft: AgentJournalEventDraft) {
        self.sequence = sequence
        self.committedAtMs = committedAtMs
        self.draft = draft
    }

    /// Semantic kind of the event.
    public var kind: AgentJournalEventKind { draft.kind }
    /// Attributed surface UUID, if attribution succeeded.
    public var surfaceId: String? { draft.surfaceId }
    /// Attributed workspace UUID, if attribution succeeded.
    public var workspaceId: String? { draft.workspaceId }
    /// Sidebar lifecycle status key the event applies to.
    public var agentKey: String { draft.agentKey }
    /// Whether the event carries a trusted target and may drive lifecycle.
    public var isAttributed: Bool {
        draft.unattributedReason == nil && draft.surfaceId != nil && draft.workspaceId != nil
    }
}
