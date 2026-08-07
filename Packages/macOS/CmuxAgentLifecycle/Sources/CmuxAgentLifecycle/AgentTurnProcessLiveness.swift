/// The externally observed liveness of the process generation that emitted a turn event.
public nonisolated enum AgentTurnProcessLiveness: String, Codable, Sendable {
    /// The exact process generation is still running.
    case live
    /// The executable boundary could not establish liveness.
    case unknown
    /// The exact process generation has exited or been replaced.
    case exited
}
