public import CmuxFoundation

/// Process observations supplied to ``RestorableAgentProcessMatcher``.
public struct RestorableAgentProcessEvidence: Sendable {
    /// The process ID from the restorable session record.
    public let processID: Int
    /// The process generation saved with the record, when available.
    public let recordedIdentity: AgentPIDProcessIdentity?
    /// The process generation observed during restore, when available.
    public let currentIdentity: AgentPIDProcessIdentity?
    /// Whether the process ID is occupied, updated when a presence probe becomes necessary.
    public var presence: RestorableAgentProcessPresence
    /// Whether argv/environment identify the recorded cmux surface, when inspectable.
    public let scopeMatches: Bool?
    /// Whether argv/environment identify the expected agent session, when inspectable.
    public let expectedProcessMatches: Bool?

    /// Creates process evidence for one recorded process ID.
    ///
    /// - Parameters:
    ///   - processID: The PID saved in the session record.
    ///   - recordedIdentity: The saved generation, or `nil` for a legacy record.
    ///   - currentIdentity: The observed generation, or `nil` if unreadable.
    ///   - presence: Whether the PID is currently occupied.
    ///   - scopeMatches: Whether the process belongs to the saved surface, or `nil` if unreadable.
    ///   - expectedProcessMatches: Whether the agent and session match, or `nil` if unreadable.
    public init(
        processID: Int,
        recordedIdentity: AgentPIDProcessIdentity?,
        currentIdentity: AgentPIDProcessIdentity?,
        presence: RestorableAgentProcessPresence,
        scopeMatches: Bool?,
        expectedProcessMatches: Bool?
    ) {
        self.processID = processID
        self.recordedIdentity = recordedIdentity
        self.currentIdentity = currentIdentity
        self.presence = presence
        self.scopeMatches = scopeMatches
        self.expectedProcessMatches = expectedProcessMatches
    }
}
