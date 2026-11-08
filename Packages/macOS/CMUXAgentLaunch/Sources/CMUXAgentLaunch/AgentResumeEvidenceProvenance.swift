/// Relative trust of durable evidence used to claim a surface resume binding.
///
/// The ordering is intentional: an interactive TUI checkpoint is stronger than
/// an unclassified record, while unclassified, automation, and nested review
/// records are never allowed to own a binding. Keeping this value in the shared
/// launch package lets future providers use the same replacement policy as Codex.
public enum AgentResumeEvidenceProvenance: Comparable, Sendable {
    /// A persisted `codex exec` or review automation checkpoint.
    case exec
    /// A persisted child-agent checkpoint.
    case subagent
    /// A durable checkpoint whose producer cannot be classified.
    case unknown
    /// A top-level interactive terminal checkpoint.
    case tui

    private var rank: Int {
        switch self {
        case .exec: 0
        case .subagent: 10
        case .unknown: 50
        case .tui: 100
        }
    }

    /// Compares the relative trust of two provenance values.
    ///
    /// - Parameters:
    ///   - lhs: The provenance on the left side of the comparison.
    ///   - rhs: The provenance on the right side of the comparison.
    /// - Returns: `true` when `lhs` is less trusted than `rhs`.
    public static func < (
        lhs: AgentResumeEvidenceProvenance,
        rhs: AgentResumeEvidenceProvenance
    ) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Whether this evidence may own a surface resume binding.
    ///
    /// Only a classified top-level interactive producer can establish a
    /// restorable foreground owner under the Codex launch policy.
    public var mayOwnBinding: Bool {
        self == .tui
    }

    /// A stable, non-sensitive value suitable for logs and telemetry.
    public var logValue: String {
        switch self {
        case .exec: "exec"
        case .subagent: "subagent"
        case .unknown: "unknown"
        case .tui: "tui"
        }
    }

    /// Checks whether this evidence may replace a verified existing binding.
    ///
    /// - Parameter existing: The provenance of the existing binding, or `nil`
    ///   when the surface has no binding.
    /// - Returns: `true` when this provenance may own the binding without a
    ///   trust downgrade.
    public func canReplace(_ existing: AgentResumeEvidenceProvenance?) -> Bool {
        guard mayOwnBinding else { return false }
        guard let existing else { return true }
        return self >= existing
    }
}
