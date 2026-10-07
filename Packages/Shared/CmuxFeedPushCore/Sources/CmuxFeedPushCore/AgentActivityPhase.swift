/// Where a running agent is, as its Live Activity shows it.
public enum AgentActivityPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case running
    case needsInput = "needs_input"
    case done
    case failed

    /// The Activity stays on screen but stops counting.
    public var isFinal: Bool { self == .done || self == .failed }
}
