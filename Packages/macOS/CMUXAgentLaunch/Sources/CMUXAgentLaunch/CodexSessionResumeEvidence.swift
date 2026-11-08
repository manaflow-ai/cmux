/// Evidence that Codex owns a concrete rollout for a session identifier.
public struct CodexSessionResumeEvidence: Equatable, Sendable {
    /// The durable Codex store that supplied the evidence.
    enum Source: Equatable, Sendable {
        /// The session was resolved through `state_5.sqlite`.
        case threadIndex
        /// The session was resolved directly from a rollout file.
        case legacyRollout
    }

    /// The exact identifier found in the rollout's `session_meta` record.
    public let sessionId: String
    /// The verified non-empty rollout file.
    let rolloutPath: String
    /// The durable store that resolved the rollout.
    let source: Source
    /// The producer classification used by the binding replacement policy.
    public let provenance: AgentResumeEvidenceProvenance
    /// The rollout's optional `originator` metadata.
    let originator: String?
    /// The rollout's string-valued `source` metadata, when present.
    let sessionMetaSource: String?
    /// The parent thread identifier reported by Codex, when present.
    let parentSessionId: String?

    /// Creates verified Codex resume evidence.
    ///
    /// - Parameters:
    ///   - sessionId: The exact identifier found in `session_meta`.
    ///   - rolloutPath: The verified non-empty rollout file.
    ///   - source: The durable store that resolved the rollout.
    ///   - provenance: The producer classification for replacement decisions.
    ///   - originator: The rollout's optional `originator` metadata.
    ///   - sessionMetaSource: The rollout's string-valued `source` metadata.
    ///   - parentSessionId: The parent thread identifier reported by Codex.
    init(
        sessionId: String,
        rolloutPath: String,
        source: Source,
        provenance: AgentResumeEvidenceProvenance,
        originator: String? = nil,
        sessionMetaSource: String? = nil,
        parentSessionId: String? = nil
    ) {
        self.sessionId = sessionId
        self.rolloutPath = rolloutPath
        self.source = source
        self.provenance = provenance
        self.originator = originator
        self.sessionMetaSource = sessionMetaSource
        self.parentSessionId = parentSessionId
    }
}
