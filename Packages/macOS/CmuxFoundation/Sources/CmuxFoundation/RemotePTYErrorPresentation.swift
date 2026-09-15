import Foundation

/// Resolves a remote PTY failure into a presentation category without owning
/// localized copy or app lifecycle state.
public struct RemotePTYErrorPresentation: Equatable, Sendable {
    /// The stable categories understood by remote PTY callers.
    public enum Kind: Equatable, Sendable {
        /// The remote daemon does not support the required PTY capability.
        case capabilityMissing
        /// The requested persistent PTY session is no longer running.
        case sessionNotFound
        /// The daemon temporarily cannot accept more PTY input.
        case inputQueueFull
        /// The remote connection or daemon is not currently usable.
        case connectionInactive
        /// The daemon has not become ready yet.
        case daemonNotReady
        /// A session-list response omitted its workspace identifier.
        case missingWorkspaceID
        /// A session-list response omitted its session identifier.
        case missingSessionID
        /// The daemon did not answer before the operation deadline.
        case timeout
        /// No known presentation category matched the failure.
        case generic
    }

    /// The category selected for the supplied failure.
    public let kind: Kind

    /// Resolves a message and optional structured code into a category.
    ///
    /// A present non-legacy structured code is authoritative, including when
    /// its value is unknown. Legacy marker matching is retained for older
    /// daemon/app pairs and for the explicit legacy envelopes.
    ///
    /// - Parameters:
    ///   - message: The daemon or transport diagnostic.
    ///   - code: The stable wire code, when one is available.
    public init(message: String, code: String?) {
        if let normalizedCode = RemotePTYErrorCode.normalized(code) {
            switch normalizedCode {
            case RemotePTYErrorCode.legacy.rawValue, "rpc_error":
                // Older app builds wrap every PTY failure in this envelope;
                // classify the embedded diagnostic below.
                break
            case RemotePTYErrorCode.capabilityMissing.rawValue:
                kind = .capabilityMissing
                return
            case RemotePTYErrorCode.sessionNotFound.rawValue:
                kind = .sessionNotFound
                return
            case RemotePTYErrorCode.inputQueueFull.rawValue:
                kind = .inputQueueFull
                return
            case RemotePTYErrorCode.connectionInactive.rawValue:
                kind = .connectionInactive
                return
            case RemotePTYErrorCode.timeout.rawValue:
                kind = .timeout
                return
            default:
                // Future codes must fail closed rather than inherit a
                // potentially misleading category from localized text.
                kind = .generic
                return
            }
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            kind = .generic
            return
        }
        let lowered = trimmed.lowercased()

        if lowered.contains("missing required capability") ||
            lowered.contains("missing required capabilities") ||
            lowered.contains("does not support persistent ssh pty sessions") ||
            lowered.contains("pty.session") ||
            lowered.contains("method_not_found") ||
            lowered.contains("unrecognized_method") {
            kind = .capabilityMissing
            return
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") &&
             (lowered.contains("not running") || lowered.contains("no longer running"))) ||
            (lowered.contains("persistent pty session") &&
             (lowered.contains("not running") || lowered.contains("no longer running"))) {
            kind = .sessionNotFound
            return
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            kind = .inputQueueFull
            return
        }
        if lowered.contains("remote connection is not active") {
            kind = .connectionInactive
            return
        }
        if lowered.contains("remote daemon is not ready") ||
            lowered.contains("remote daemon tunnel is not ready") {
            kind = .daemonNotReady
            return
        }
        if lowered.contains("missing workspace_id in ssh pty session list response") {
            kind = .missingWorkspaceID
            return
        }
        if lowered.contains("missing session_id in ssh pty session list response") {
            kind = .missingSessionID
            return
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            kind = .timeout
            return
        }

        kind = .generic
    }

    /// Resolves an error using its diagnostic and explicit structured code.
    ///
    /// When no code is attached to the error, the diagnostic is treated as a
    /// legacy message first. A known code inferred from a local transport seam
    /// is used only when that message has no more specific legacy marker.
    ///
    /// - Parameter error: The remote PTY failure to classify.
    public init(error: any Error) {
        let message = error.localizedDescription
        if let structuredCode = RemotePTYErrorCode.structuredCode(from: error) {
            self.init(message: message, code: structuredCode)
            return
        }

        let legacyPresentation = Self(message: message, code: nil)
        guard legacyPresentation.kind == .generic else {
            self = legacyPresentation
            return
        }

        self.init(message: message, code: RemotePTYErrorCode.code(for: error))
    }
}
