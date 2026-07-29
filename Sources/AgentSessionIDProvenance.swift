/// Describes whether cmux can trust an agent session identifier as panel-specific.
enum AgentSessionIDProvenance: String, Codable, Hashable, Sendable {
    /// The harness or its structured launch arguments supplied the identifier.
    case authoritative
    /// Process detection selected the newest session file heuristically.
    case inferredLatestSessionFile
    /// Process detection retained a fork parent's identifier as a fallback.
    case forkParentFallback
    /// The process can be relaunched but has no resumable session identifier.
    case relaunchOnly
}
