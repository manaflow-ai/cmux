public import Foundation

/// One semantic agent event as emitted by a producer (the cmux CLI hook
/// handlers), before the journal assigns it a sequence number.
///
/// The draft is the wire format of the `agent_journal_append` socket verb: a
/// single-line JSON object with snake_case keys. Identity fields record the
/// attribution *decided at emit time*; an event that could not be attributed
/// carries ``unattributedReason`` instead of a guessed target and is preserved
/// as a diagnostic rather than dropped.
public struct AgentJournalEventDraft: Codable, Sendable, Equatable {
    /// Wire schema version; bump when the draft shape changes incompatibly.
    public static let currentSchemaVersion = 1

    /// Longest accepted ``detail`` in UTF-8 bytes; longer values are
    /// truncated on a character boundary.
    public static let maximumDetailLength = 500

    /// Schema version of this draft (``currentSchemaVersion`` for new events).
    public var schemaVersion: Int
    /// Producer-chosen globally unique id; the journal's idempotency key.
    public var eventId: String
    /// Semantic kind of the event.
    public var kind: AgentJournalEventKind
    /// Producer wall-clock timestamp in milliseconds since the Unix epoch.
    public var occurredAtMs: Int64
    /// Adapter that produced the event (stable agent slug, e.g. `claude`).
    public var source: String
    /// Sidebar lifecycle status key the event applies to (e.g. `claude_code`).
    public var agentKey: String
    /// Native agent session id, when the adapter exposes one.
    public var sessionId: String?
    /// Workspace UUID the event was attributed to, if attribution succeeded.
    public var workspaceId: String?
    /// Surface (panel) UUID the event was attributed to, if attribution
    /// succeeded. Lifecycle reduction requires this; without it the event is
    /// diagnostic-only.
    public var surfaceId: String?
    /// Why attribution failed, when it did. Mutually exclusive with a trusted
    /// target: emitters must never populate both this and a guessed
    /// workspace/surface pair.
    public var unattributedReason: String?
    /// Whether the event came from a nested (sub)agent session. Subagent
    /// events are journaled but excluded from surface lifecycle reduction.
    public var isSubagent: Bool
    /// For ``AgentJournalEventKind/turnCompleted``: the turn ended but
    /// background work is still live, so the agent is still effectively
    /// running.
    public var pendingWork: Bool
    /// The adapter's native hook event name, kept for diagnostics and for
    /// auditing the semantic mapping.
    public var nativeEvent: String?
    /// Explicit phase assertion, honored only for
    /// ``AgentJournalEventKind/stateChanged`` events (used by correction
    /// paths that restore a known-good phase after a stale event).
    public var declaredPhase: AgentLifecyclePhase?
    /// Short human-readable context (e.g. a failure summary). Bounded by
    /// ``maximumDetailLength``.
    public var detail: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventId = "event_id"
        case kind
        case occurredAtMs = "occurred_at_ms"
        case source
        case agentKey = "agent_key"
        case sessionId = "session_id"
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case unattributedReason = "unattributed_reason"
        case isSubagent = "is_subagent"
        case pendingWork = "pending_work"
        case nativeEvent = "native_event"
        case declaredPhase = "declared_phase"
        case detail
    }

    /// Creates a draft, stamping the current schema version and truncating
    /// ``detail`` to its bound.
    ///
    /// - Parameters:
    ///   - eventId: Globally unique idempotency key (defaults to a fresh UUID).
    ///   - kind: Semantic kind of the event.
    ///   - occurredAtMs: Producer timestamp in ms since the Unix epoch.
    ///   - source: Stable agent slug of the producing adapter.
    ///   - agentKey: Sidebar lifecycle status key.
    ///   - sessionId: Native session id, if any.
    ///   - workspaceId: Attributed workspace UUID, if attribution succeeded.
    ///   - surfaceId: Attributed surface UUID, if attribution succeeded.
    ///   - unattributedReason: Why attribution failed, when it did.
    ///   - isSubagent: Whether the event came from a nested agent session.
    ///   - pendingWork: Whether a completed turn left live background work.
    ///   - nativeEvent: The adapter's native hook event name.
    ///   - declaredPhase: Explicit phase assertion for `stateChanged` events.
    ///   - detail: Short human-readable context.
    public init(
        eventId: String = UUID().uuidString,
        kind: AgentJournalEventKind,
        occurredAtMs: Int64,
        source: String,
        agentKey: String,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        unattributedReason: String? = nil,
        isSubagent: Bool = false,
        pendingWork: Bool = false,
        nativeEvent: String? = nil,
        declaredPhase: AgentLifecyclePhase? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.eventId = eventId
        self.kind = kind
        self.occurredAtMs = occurredAtMs
        self.source = source
        self.agentKey = agentKey
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.unattributedReason = unattributedReason
        self.isSubagent = isSubagent
        self.pendingWork = pendingWork
        self.nativeEvent = nativeEvent
        self.declaredPhase = declaredPhase
        self.detail = detail.map(Self.boundedDetail)
    }

    /// Validates the draft for journal admission.
    ///
    /// - Returns: A human-readable problem description, or `nil` when the
    ///   draft is acceptable.
    public func validationProblem() -> String? {
        if schemaVersion < 1 { return "schema_version must be >= 1" }
        if eventId.isEmpty || eventId.count > 128 { return "event_id must be 1-128 characters" }
        if occurredAtMs < 0 { return "occurred_at_ms must be >= 0" }
        if !Self.isValidSlug(source) { return "source must be a 1-64 character lowercase slug" }
        if !Self.isValidSlug(agentKey) { return "agent_key must be a 1-64 character lowercase slug" }
        if let workspaceId, UUID(uuidString: workspaceId) == nil { return "workspace_id must be a UUID" }
        if let surfaceId, UUID(uuidString: surfaceId) == nil { return "surface_id must be a UUID" }
        if unattributedReason != nil, workspaceId != nil || surfaceId != nil {
            return "unattributed events must not carry a target"
        }
        if (workspaceId == nil) != (surfaceId == nil) {
            return "attribution requires both workspace_id and surface_id"
        }
        if workspaceId == nil, surfaceId == nil, unattributedReason == nil {
            return "an event without a target must carry unattributed_reason"
        }
        if let unattributedReason, unattributedReason.isEmpty || unattributedReason.count > 128 {
            return "unattributed_reason must be 1-128 characters"
        }
        if let detail, detail.utf8.count > Self.maximumDetailLength {
            return "detail exceeds \(Self.maximumDetailLength) UTF-8 bytes"
        }
        return nil
    }

    /// Truncates `value` to ``maximumDetailLength`` UTF-8 bytes on a
    /// character boundary.
    ///
    /// - Parameter value: The raw detail text.
    /// - Returns: The bounded detail.
    public static func boundedDetail(_ value: String) -> String {
        guard value.utf8.count > maximumDetailLength else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            if bytes + characterBytes > maximumDetailLength { break }
            bytes += characterBytes
            result.append(character)
        }
        return result
    }

    /// Whether `value` is a valid lowercase agent slug (1-64 characters of
    /// `[a-z0-9._-]`), matching the notification meta grammar both sides of
    /// the socket already agree on.
    public static func isValidSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
    }
}
