/// The complete value-only result of one manifest evaluation.
public struct CmuxAgentDetectionResult: Codable, Equatable, Hashable, Sendable {
    /// The selected manifest identifier, or `nil` when identity did not match.
    public let agentID: String?
    /// The selected manifest display name.
    public let displayName: String?
    /// The selected manifest's source tier.
    public let source: CmuxAgentManifestSource?
    /// The selected user manifest path, if applicable.
    public let sourcePath: String?
    /// The process matcher that selected the manifest.
    public let processMatcherID: String?
    /// The resulting terminal state.
    public let classification: CmuxAgentClassification
    /// The first state rule that matched, if any.
    public let stateRuleID: String?
    /// The bounded process/state evaluation trace.
    public let trace: [CmuxAgentRuleTrace]

    /// Creates a detection result.
    public init(
        agentID: String?,
        displayName: String?,
        source: CmuxAgentManifestSource?,
        sourcePath: String?,
        processMatcherID: String?,
        classification: CmuxAgentClassification,
        stateRuleID: String?,
        trace: [CmuxAgentRuleTrace]
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.source = source
        self.sourcePath = sourcePath
        self.processMatcherID = processMatcherID
        self.classification = classification
        self.stateRuleID = stateRuleID
        self.trace = trace
    }
}
