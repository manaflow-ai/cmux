/// Defines which lifecycle identity owns an integration's agent process.
public nonisolated enum AgentLifecycleProcessOwnershipScope: Hashable, Sendable {
    /// Each session owns a distinct agent process generation.
    case session
    /// Multiple sessions share one long-lived agent process generation.
    case sharedProcess

    /// Returns the PID-registration key for one hook observation.
    ///
    /// Shared-process integrations aggregate sessions only when cmux can bind
    /// them to the same positive process identifier. Without that evidence,
    /// they fall back to session ownership so unrelated processes cannot steal
    /// each other's panel-scoped runtime.
    ///
    /// - Parameters:
    ///   - statusKey: The integration's root lifecycle status key.
    ///   - sessionId: The hook session identifier, or an empty string when unavailable.
    ///   - processID: The inferred positive agent process identifier, when available.
    /// - Returns: The stable key used by PID registration and cleanup commands.
    public func agentPIDKey(
        statusKey: String,
        sessionId: String,
        processID: Int?
    ) -> String {
        let sessionKey = "\(statusKey).\(sessionId.isEmpty ? "default" : sessionId)"
        switch self {
        case .session:
            return sessionKey
        case .sharedProcess:
            guard let processID, processID > 0 else {
                return sessionKey
            }
            return "\(statusKey).process.\(processID)"
        }
    }
}
