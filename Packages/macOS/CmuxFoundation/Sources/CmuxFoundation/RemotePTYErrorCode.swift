import Foundation

/// Stable machine-readable failure categories shared by the remote PTY
/// daemon, app socket, bridge status line, and CLI.
///
/// Human-readable PTY errors remain a display/legacy-compatibility surface.
/// Callers that need retry or respawn semantics should use the code returned by
/// ``code(for:)`` (or a wire code directly) instead of parsing that text.
///
/// ```swift
/// let code = RemotePTYErrorCode.code(for: error)
/// ```
public enum RemotePTYErrorCode: String, CaseIterable, Sendable {
    /// The pre-subcode v2 envelope used by older app builds.
    case legacy = "remote_pty_error"

    /// The daemon or proxy did not answer before the operation deadline.
    case timeout = "remote_pty_timeout"

    /// The remote connection/daemon transport is not currently usable.
    case connectionInactive = "remote_connection_inactive"

    /// The daemon could not accept another PTY input write yet.
    case inputQueueFull = "pty_input_queue_full"

    /// The requested persistent PTY session is gone.
    case sessionNotFound = "pty_session_not_found"

    /// The remote daemon does not implement the persistent PTY capability.
    case capabilityMissing = "remote_pty_capability_missing"

    /// A PTY attach failed for a known, non-transient reason.
    case attachFailed = "remote_pty_attach_failed"

    /// The app-side lifecycle was intentionally closed.
    case lifecycleClosed = "pty_lifecycle_closed"

    /// Existing daemon admission-pressure code. This is retained as a stable
    /// code because older clients already use it to retry without reauth.
    case unavailable = "unavailable"

    /// The sender and daemon disagreed about sequenced input ordering.
    case inputSequenceGap = "pty_input_seq_gap"

    /// The daemon failed while creating a new persistent PTY session.
    case startFailed = "pty_start_failed"

    /// A tokenized PTY attachment disappeared while an operation was in flight.
    case attachmentNotFound = "pty_attachment_not_found"

    /// NSError userInfo key used by the Swift daemon client to preserve a
    /// daemon response code across the synchronous RPC boundary.
    public static let rpcErrorCodeUserInfoKey = "cmux.remote.daemon.rpc.error_code"

    /// Returns a trimmed non-empty wire code.
    public static func normalized(_ rawCode: String?) -> String? {
        guard let rawCode else { return nil }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// Returns a structured daemon code attached to an NSError, if present.
    public static func structuredCode(from error: any Error) -> String? {
        normalized((error as NSError).userInfo[rpcErrorCodeUserInfoKey] as? String)
    }

    /// Returns the stable v2/bridge code for an error.
    ///
    /// Structured daemon codes win. The legacy generic envelope is deliberately
    /// reclassified from its message so an older wrapper can still recover when
    /// talking to a newer app. Unknown structured codes are preserved; consumers
    /// can therefore fail closed instead of guessing from localized text.
    public static func code(for error: any Error) -> String {
        let nsError = error as NSError
        if let structuredCode = structuredCode(from: error) {
            switch structuredCode {
            case Self.legacy.rawValue, "rpc_error":
                return code(forMessage: nsError.localizedDescription)
            case "method_not_found", "unrecognized_method":
                return capabilityMissing.rawValue
            case "not_found":
                let messageCode = code(forMessage: nsError.localizedDescription)
                if messageCode == sessionNotFound.rawValue ||
                    messageCode == attachmentNotFound.rawValue {
                    return messageCode
                }
                return structuredCode
            default:
                return structuredCode
            }
        }

        // These local NSError codes are the established synchronous PTY seams.
        // Keep their messages unchanged while assigning a stable category.
        if nsError.domain == "cmux.remote.daemon.rpc" {
            switch nsError.code {
            case 2:
                return capabilityMissing.rawValue
            case 11, 25:
                return timeout.rawValue
            case 1, 12, 13, 15, 16, 18, 19, 20:
                return connectionInactive.rawValue
            default:
                break
            }
        }
        if nsError.domain == "cmux.remote.daemon", nsError.code == 43 {
            return capabilityMissing.rawValue
        }
        if nsError.domain == "cmux.remote.pty" {
            switch nsError.code {
            case 3, 8, 20:
                return timeout.rawValue
            case 1, 2, 5, 6, 7, 10, 11, 13, 14, 30, 31, 32, 33, 34, 40:
                return connectionInactive.rawValue
            default:
                break
            }
        }
        return code(forMessage: nsError.localizedDescription)
    }

    /// Classifies a legacy human-readable error when no structured code exists.
    /// This is intentionally narrow and is only a compatibility fallback.
    public static func code(forMessage message: String) -> String {
        let lowered = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if lowered.contains("missing required capability") ||
            lowered.contains("missing required capabilities") ||
            lowered.contains("does not support persistent ssh pty sessions") ||
            lowered.contains("missing required functionality") ||
            lowered.contains("pty.session") ||
            lowered.contains("method_not_found") ||
            lowered.contains("unrecognized_method") {
            return capabilityMissing.rawValue
        }
        if lowered.contains("pty_session_not_found") ||
            ((lowered.contains("persistent ssh pty session") ||
              lowered.contains("persistent pty session")) &&
             (lowered.contains("not running") || lowered.contains("no longer running"))) ||
            (lowered.contains("pty session") && lowered.contains("not found")) {
            return sessionNotFound.rawValue
        }
        if lowered.contains("pty_input_queue_full") ||
            lowered.contains("pty input queue is full") ||
            lowered.contains("input is temporarily backed up") {
            return inputQueueFull.rawValue
        }
        if lowered.contains("pty_input_seq_gap") ||
            lowered.contains("pty input sequence gap") {
            return inputSequenceGap.rawValue
        }
        if lowered.contains("pty_lifecycle_closed") {
            return lifecycleClosed.rawValue
        }
        if lowered.contains("timed out") ||
            lowered.contains("timeout") ||
            lowered.contains("did not respond in time") {
            return timeout.rawValue
        }
        if lowered.contains("remote connection is not active") ||
            lowered.contains("remote daemon is not ready") ||
            lowered.contains("remote daemon tunnel is not ready") ||
            lowered.contains("connection refused") ||
            lowered.contains("connection reset") {
            return connectionInactive.rawValue
        }
        if lowered.contains("too many pty") && lowered.contains("already") {
            return unavailable.rawValue
        }
        if lowered.contains("remote_pty_capability_missing") {
            return capabilityMissing.rawValue
        }
        if lowered.contains("pty_start_failed") {
            return startFailed.rawValue
        }
        if lowered.contains("remote_pty_attach_failed") {
            return attachFailed.rawValue
        }
        if lowered.contains("pty_attachment_not_found") ||
            (lowered.contains("pty attachment") && lowered.contains("not found")) {
            return attachmentNotFound.rawValue
        }
        return attachFailed.rawValue
    }

    /// Whether a code belongs to this published taxonomy.
    public static func isKnown(_ rawCode: String?) -> Bool {
        guard let code = normalized(rawCode) else { return false }
        return Self(rawValue: code) != nil
    }
}
