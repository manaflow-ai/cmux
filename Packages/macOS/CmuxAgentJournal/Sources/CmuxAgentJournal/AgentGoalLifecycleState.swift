/// The provider-independent lifecycle of a persistent agent objective.
public enum AgentGoalLifecycleState: String, Codable, Sendable, CaseIterable, Equatable {
    /// The objective is being actively pursued.
    case active
    /// The objective is intentionally resumable after an external transition.
    case paused
    /// The objective cannot proceed without an external decision or change.
    case blocked
    /// The exact objective generation reached its terminal outcome.
    case complete
    /// The provider does not expose a persistent objective for this session.
    case unmanaged
    /// Objective support exists or may exist, but authoritative state is unavailable.
    case unknown

    /// Whether this state is a terminal no-resume boundary for its generation.
    public var isTerminal: Bool { self == .complete }

    /// Decodes unsupported provider values as `unknown` so consumers fail closed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    /// Maps a provider status into the public objective contract.
    ///
    /// Providers commonly use budget or usage limits for a state that cannot
    /// proceed without an external transition. Those values become ``blocked``;
    /// every unsupported value becomes ``unknown`` rather than ``complete``.
    ///
    /// - Parameter providerValue: A provider status string.
    /// - Returns: The fail-closed public objective state.
    public static func fromProviderValue(_ providerValue: String) -> Self {
        switch providerValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active": return .active
        case "paused": return .paused
        case "blocked", "usagelimited", "budgetlimited": return .blocked
        case "complete": return .complete
        case "unmanaged": return .unmanaged
        default: return .unknown
        }
    }
}
