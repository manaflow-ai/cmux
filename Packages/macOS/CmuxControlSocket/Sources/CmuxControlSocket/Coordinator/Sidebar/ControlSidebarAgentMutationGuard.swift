public import Foundation

/// Occupant identity that authorizes one deferred agent-owned UI mutation.
///
/// Every consumer revalidates this identity at its final main-actor apply
/// boundary so a delayed hook cannot mutate the process or session that
/// replaced it while the command was queued.
public enum ControlSidebarAgentMutationGuard: Equatable, Sendable {
    /// Authorizes a mutation only while one lifecycle session owns the status key.
    ///
    /// - Parameters:
    ///   - statusKey: Sidebar status and lifecycle key owned by the session.
    ///   - sessionID: Exact authoritative lifecycle-session identifier.
    case session(statusKey: String, sessionID: String)

    /// Authorizes a mutation only while one exact process generation owns the status key.
    ///
    /// - Parameters:
    ///   - statusKey: Sidebar status and lifecycle key owned by the process.
    ///   - pidKey: PID-routing key recorded for the anonymous occupant.
    ///   - pid: Darwin process identifier recorded for the occupant.
    ///   - startSeconds: Whole seconds in the kernel-recorded process birth time.
    ///   - startMicroseconds: Microsecond component of the process birth time.
    case process(
        statusKey: String,
        pidKey: String,
        pid: Int32,
        startSeconds: Int64,
        startMicroseconds: Int64
    )

    /// Versioned, delimiter-safe representation for the notification meta field.
    ///
    /// The envelope contains only ASCII without spaces, semicolons, or pipe
    /// characters, so it can occupy the established notification metadata
    /// segment without inspecting user-authored title, subtitle, or body text.
    public var socketEnvelope: String {
        switch self {
        case let .session(statusKey, sessionID):
            return [
                "v1",
                "s",
                statusKey.controlSidebarAgentMutationGuardBase64Encoded,
                sessionID.controlSidebarAgentMutationGuardBase64Encoded,
            ].joined(separator: ":")
        case let .process(statusKey, pidKey, pid, seconds, microseconds):
            return [
                "v1",
                "p",
                statusKey.controlSidebarAgentMutationGuardBase64Encoded,
                pidKey.controlSidebarAgentMutationGuardBase64Encoded,
                String(pid),
                String(seconds),
                String(microseconds),
            ].joined(separator: ":")
        }
    }

    /// Creates a guard from a versioned notification-metadata envelope.
    ///
    /// - Parameter socketEnvelope: Envelope produced by a trusted cmux hook client.
    public init?(socketEnvelope: String) {
        let fields = socketEnvelope.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.first == "v1" else { return nil }
        if fields.count == 4, fields[1] == "s" {
            guard let statusKey = fields[2].controlSidebarAgentMutationGuardBase64Decoded,
                  let sessionID = fields[3].controlSidebarAgentMutationGuardBase64Decoded else {
                return nil
            }
            self = .session(statusKey: statusKey, sessionID: sessionID)
            return
        }
        guard fields.count == 7,
              fields[1] == "p",
              let statusKey = fields[2].controlSidebarAgentMutationGuardBase64Decoded,
              let pidKey = fields[3].controlSidebarAgentMutationGuardBase64Decoded,
              let pid = Int32(fields[4]),
              pid > 0,
              let seconds = Int64(fields[5]),
              seconds >= 0,
              let microseconds = Int64(fields[6]),
              microseconds >= 0,
              microseconds < 1_000_000 else {
            return nil
        }
        self = .process(
            statusKey: statusKey,
            pidKey: pidKey,
            pid: pid,
            startSeconds: seconds,
            startMicroseconds: microseconds
        )
    }
}

private extension String {
    var controlSidebarAgentMutationGuardBase64Encoded: String {
        Data(utf8).base64EncodedString()
    }

    var controlSidebarAgentMutationGuardBase64Decoded: String? {
        guard let data = Data(base64Encoded: self),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded.controlSidebarAgentMutationGuardNormalized
    }

    var controlSidebarAgentMutationGuardNormalized: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
