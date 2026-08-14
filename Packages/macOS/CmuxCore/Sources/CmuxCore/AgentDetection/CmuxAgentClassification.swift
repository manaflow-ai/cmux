/// A state classification produced by a manifest state rule.
public enum CmuxAgentClassification: String, Codable, Hashable, Sendable {
    /// No process or state rule matched.
    case unknown
    /// The agent is waiting at its normal prompt.
    case idle
    /// The agent is actively processing work.
    case working
    /// The agent is waiting for input or reported a blocked condition.
    case blocked
    /// The agent is showing a permission or approval prompt.
    case permissionPrompt = "permission-prompt"
    /// The agent reported a completed turn.
    case done
}
