internal import Foundation

/// Defines which lifecycle identity owns an integration's agent process.
public nonisolated enum AgentLifecycleProcessOwnershipScope: Hashable, Sendable {
    /// Each session owns a distinct agent process generation.
    case session
    /// Multiple sessions share one long-lived agent process generation.
    case sharedProcess

    /// Returns the PID-registration key for one hook observation.
    ///
    /// Shared-process integrations aggregate sessions only when cmux can bind
    /// them to the same exact process generation. A numeric PID alone is not
    /// sufficient because the kernel can reuse it after a process exits.
    ///
    /// - Parameters:
    ///   - statusKey: The integration's root lifecycle status key.
    ///   - sessionId: The hook session identifier, or an empty string when unavailable.
    ///   - processGeneration: The exact inferred agent process generation, when
    ///     available.
    /// - Returns: The stable key used by PID registration and cleanup commands,
    ///   or `nil` when neither the session nor exact process evidence can own it.
    public func agentPIDKey(
        statusKey: String,
        sessionId: String,
        processGeneration: AgentProcessGeneration?
    ) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let sessionKey = normalizedSessionId.isEmpty
            ? nil
            : "\(statusKey).\(normalizedSessionId)"
        let processKey = processGeneration.flatMap { generation -> String? in
            guard generation.pid > 0,
                  generation.startSeconds >= 0,
                  (0 ..< 1_000_000).contains(
                      generation.startMicroseconds
                  ) else {
                return nil
            }
            return "\(statusKey).process.\(generation.pid)."
                + "\(generation.startSeconds)."
                + "\(generation.startMicroseconds)"
        }
        switch self {
        case .session:
            return sessionKey ?? processKey
        case .sharedProcess:
            return processKey ?? sessionKey
        }
    }
}
