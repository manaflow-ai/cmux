import Foundation

/// Owns ssh-pty-attach exit-code semantics.
///
/// Exit codes 254 and 255 are the only retryable statuses recognized by the
/// embedded wrapper loops in `SSHPTYAttachStartupCommandBuilder.retryingAttachLines`
/// and `CMUXCLI.sshPTYAttachRetryLoopLines`; keep those shell contracts in sync
/// with this taxonomy. The classifier patterns mirror
/// `userFacingRemotePTYErrorMessage` in `CLI/CMUXCLI+RemotePTYErrors.swift`.
nonisolated enum SSHPTYAttachExitCode: Int32 {
    case fatal = 1
    case sessionNotFound = 253
    case bridgeClosedSessionRunning = 254
    case retryableTransient = 255

    static func classifyBridgeEstablishmentFailure(_ rawDescription: String) -> SSHPTYAttachExitCode {
        classifyNormalized(rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func classifyBridgeEstablishmentFailure(code: String?, message: String) -> SSHPTYAttachExitCode {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedCode == "pty_session_not_found" {
            return .sessionNotFound
        }
        let rawDescription = [normalizedCode, message]
            .compactMap { $0 }
            .joined(separator: " ")
        return classifyBridgeEstablishmentFailure(rawDescription)
    }

    private static func classifyNormalized(_ description: String) -> SSHPTYAttachExitCode {
        if description.contains("pty_session_not_found") ||
            ((description.contains("persistent ssh pty session") ||
              description.contains("persistent pty session")) &&
             description.contains("not running")) {
            return .sessionNotFound
        }

        if description.contains("timed out") ||
            description.contains("timeout") ||
            description.contains("did not respond in time") ||
            description.contains("remote connection is not active") ||
            description.contains("remote daemon is not ready") ||
            description.contains("remote daemon tunnel is not ready") ||
            description.contains("pty_input_queue_full") ||
            description.contains("pty input queue is full") ||
            description.contains("connection refused") ||
            description.contains("connection reset") {
            return .retryableTransient
        }

        return .fatal
    }
}
