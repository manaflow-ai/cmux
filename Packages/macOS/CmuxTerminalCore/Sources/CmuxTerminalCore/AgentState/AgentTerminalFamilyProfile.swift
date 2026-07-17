/// Validated, data-driven identity and terminal evidence for one agent family.
public struct AgentTerminalFamilyProfile: Sendable, Equatable {
    /// Canonical detector identifier.
    public let id: String
    /// Existing cmux lifecycle/status key used by sidebar integration.
    public let statusKey: String
    /// Canonical hook/session provider identifier used by `cmux agents`.
    public let sessionProviderID: String
    /// Human-readable family name for diagnostics.
    public let displayName: String
    /// Whether a complete official lifecycle integration may own semantic state.
    public let lifecycleAuthoritative: Bool
    /// Executable basenames that directly identify this family.
    public let executableBasenames: Set<String>
    /// Command-line fragments that reveal this family behind a generic runtime.
    public let argumentNeedles: [String]
    /// Accepted values of cmux-owned wrapper hints.
    public let hintAliases: Set<String>
    /// Current live-bottom fragments that strongly indicate an idle composer.
    public let idleNeedles: [String]
    /// Current live-bottom evidence groups that indicate active work.
    ///
    /// Every fragment in one inner group must match. Any complete group is
    /// sufficient. This keeps generic words from becoming standalone signals.
    public let workingEvidenceGroups: [[String]]
    /// Strict current-interaction evidence groups that require human input.
    public let blockedEvidenceGroups: [[String]]
    /// High-confidence prompts that require human input when they occupy a rendered line.
    public let blockedExactLines: [String]
    /// Agent-owned history/transcript fragments that suppress new classification.
    public let historyViewNeedles: [String]

    /// Creates one profile. Catalog validation rejects empty or duplicate identity data.
    public init(
        id: String,
        statusKey: String,
        sessionProviderID: String? = nil,
        displayName: String,
        lifecycleAuthoritative: Bool = false,
        executableBasenames: Set<String>,
        argumentNeedles: [String] = [],
        hintAliases: Set<String> = [],
        idleNeedles: [String] = [],
        workingEvidenceGroups: [[String]] = [],
        blockedEvidenceGroups: [[String]] = [],
        blockedExactLines: [String] = [],
        historyViewNeedles: [String] = []
    ) {
        self.id = id
        self.statusKey = statusKey
        self.sessionProviderID = sessionProviderID ?? statusKey
        self.displayName = displayName
        self.lifecycleAuthoritative = lifecycleAuthoritative
        self.executableBasenames = executableBasenames
        self.argumentNeedles = argumentNeedles
        self.hintAliases = hintAliases
        self.idleNeedles = idleNeedles
        self.workingEvidenceGroups = workingEvidenceGroups
        self.blockedEvidenceGroups = blockedEvidenceGroups
        self.blockedExactLines = blockedExactLines
        self.historyViewNeedles = historyViewNeedles
    }
}
