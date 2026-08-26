/// How a structured restore record constructs its final process invocation.
public enum AgentRestoreRequestMode: String, Codable, Sendable {
    /// Rebuild an agent's resume argv from its captured launch.
    case resumeAgent
    /// Rebuild a relaunch-only agent invocation.
    case relaunchAgent
    /// Execute the recorded argv exactly.
    case direct
}
