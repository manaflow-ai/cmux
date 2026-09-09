import Foundation

/// Builds and validates the private lifecycle token used by hooks delivered
/// through a remote terminal relay.
///
/// Relay hooks run in a different PID namespace from the Mac app. Including
/// the terminal lifecycle, SSH attempt, and process birth timestamp in the
/// token keeps a delayed hook from being accepted by a later occupant that
/// happens to reuse the provider-visible session ID.
public enum AgentRelayLifecycle {
    private static let marker = "#relay#"

    /// Removes the private relay suffix before a token crosses a public
    /// surface-resume boundary.
    public static func publicSessionID(_ sessionID: String) -> String {
        guard let range = sessionID.range(of: marker) else { return sessionID }
        return String(sessionID[..<range.lowerBound])
    }

    /// Mints a generation token for a provider-visible session ID.
    public static func inferredGeneration(
        sessionID: String,
        environment: [String: String],
        pid: Int,
        startSeconds: Int64,
        startMicroseconds: Int64
    ) -> String? {
        guard let sessionID = normalized(sessionID),
              !sessionID.contains(marker),
              let terminalLifecycleID = uuidValue(environment["CMUX_TERMINAL_LIFECYCLE_ID"]),
              let attemptID = uuidValue(environment["CMUX_SSH_ATTEMPT_ID"]),
              pid > 0,
              pid <= Int(Int32.max),
              startSeconds >= 0,
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }

        return "\(sessionID)\(marker)\(terminalLifecycleID.uuidString)"
            + "#\(attemptID.uuidString)#\(pid)#\(startSeconds)#\(startMicroseconds)"
    }

    /// Validates a generation token already carried by a detached monitor.
    public static func existingGeneration(
        sessionID: String,
        environment: [String: String]
    ) -> String? {
        guard let sessionID = normalized(sessionID),
              let markerRange = sessionID.range(of: marker),
              !sessionID[..<markerRange.lowerBound].isEmpty,
              sessionID[markerRange.upperBound...].range(of: marker) == nil else {
            return nil
        }

        let fields = sessionID[markerRange.upperBound...]
            .split(separator: "#", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let terminalLifecycleID = UUID(uuidString: String(fields[0])),
              let attemptID = UUID(uuidString: String(fields[1])),
              let pid = Int(String(fields[2])),
              pid > 0,
              pid <= Int(Int32.max),
              let startSeconds = Int64(String(fields[3])),
              startSeconds >= 0,
              let startMicroseconds = Int64(String(fields[4])),
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }

        if let rawTerminalLifecycleID = normalized(environment["CMUX_TERMINAL_LIFECYCLE_ID"]),
           UUID(uuidString: rawTerminalLifecycleID) != terminalLifecycleID {
            return nil
        }
        if let rawAttemptID = normalized(environment["CMUX_SSH_ATTEMPT_ID"]),
           UUID(uuidString: rawAttemptID) != attemptID {
            return nil
        }
        return sessionID
    }

    private static func uuidValue(_ value: String?) -> UUID? {
        guard let value = normalized(value) else { return nil }
        return UUID(uuidString: value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
