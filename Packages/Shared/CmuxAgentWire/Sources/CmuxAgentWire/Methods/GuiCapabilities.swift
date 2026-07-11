public import CmuxAgentReplica

/// Parameters for requesting one session's GUI capability report.
public struct GuiCapabilitiesParams: Codable, Hashable, Sendable {
    /// The session whose capabilities are requested.
    public let sessionID: AgentSessionID

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }

    /// Creates capability-report parameters.
    /// - Parameter sessionID: The session whose capabilities are requested.
    public init(sessionID: AgentSessionID) {
        self.sessionID = sessionID
    }
}

/// Wire-owned GUI capability report for one agent session.
///
/// Mac-only truth types must map into this value instead of crossing the shared
/// package boundary.
public struct GuiCapabilitiesResult: Codable, Hashable, Sendable {
    /// The session's current detection tier.
    public let tier: DetectionTier
    /// Open machine-readable reasons explaining capability limitations.
    public let reasons: [GuiCapabilityReason]
    /// The detected agent CLI version, when available.
    public let cliVersion: String?
    /// Whether the session accepts steering input.
    public let steerable: Bool
    /// Whether the session accepts structured answers.
    public let answerable: Bool

    private enum CodingKeys: String, CodingKey {
        case tier
        case reasons
        case cliVersion = "cli_version"
        case steerable
        case answerable
    }

    /// Creates a GUI capability report.
    /// - Parameters:
    ///   - tier: The session's current detection tier.
    ///   - reasons: Open machine-readable capability reasons.
    ///   - cliVersion: The detected CLI version, when available.
    ///   - steerable: Whether the session accepts steering input.
    ///   - answerable: Whether the session accepts structured answers.
    public init(
        tier: DetectionTier,
        reasons: [GuiCapabilityReason],
        cliVersion: String? = nil,
        steerable: Bool,
        answerable: Bool
    ) {
        self.tier = tier
        self.reasons = reasons
        self.cliVersion = cliVersion
        self.steerable = steerable
        self.answerable = answerable
    }
}
