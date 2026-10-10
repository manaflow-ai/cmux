import Foundation

/// Whether a terminal tab's shell runs, and why a dead one ended (R41,
/// plans/cmux-next/durable-sessions.md section 7). Wire `terminal_state`.
public enum TerminalTabState: String, Sendable, Hashable, Decodable {
    case running
    /// A restarted daemon is still adopting the terminal's host; the shell runs.
    case adopting
    /// The host's record is one this daemon build cannot adopt; the shell may
    /// still run until the user closes the tab.
    case unadoptable
    /// The daemon lost its link to the terminal's host and is reconnecting.
    case reconnecting
    /// The daemon gave up reconnecting to the host; the shell may still run.
    case failed
    case exited
}

/// How a dead terminal ended. Wire `end` on the tab.
public struct TerminalTabEnd: Sendable, Hashable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// The process exited with `code`.
        case exited
        /// The process was killed by `signal`.
        case signaled
        /// The terminal host was lost (crash, kill, logout); `reason` says how.
        case hostLost = "host_lost"
        /// The terminal never started.
        case launchFailed = "launch_failed"
    }

    /// Stable host-loss reasons; unknown future values decode as `.other`.
    public enum HostLostReason: String, Sendable, Hashable, Decodable {
        case missingRecord = "missing_record"
        case incarnationMismatch = "incarnation_mismatch"
        case deadBeforeAdoption = "dead_before_adoption"
        case diedDuringAdoption = "died_during_adoption"
        case diedWithoutExitStatus = "died_without_exit_status"
        case missingExitReceipt = "missing_exit_receipt"
        case sessionShutdown = "session_shutdown"
        /// A host this daemon could not adopt ended (by itself or on close).
        case unadoptableHostEnded = "unadoptable_host_ended"
        case other

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = HostLostReason(rawValue: raw) ?? .other
        }
    }

    public var kind: Kind
    public var code: Int32?
    public var signal: Int32?
    public var coreDumped: Bool?
    public var reason: HostLostReason?
    public var detail: String?

    public init(kind: Kind, code: Int32? = nil, signal: Int32? = nil, coreDumped: Bool? = nil,
                reason: HostLostReason? = nil, detail: String? = nil) {
        self.kind = kind
        self.code = code
        self.signal = signal
        self.coreDumped = coreDumped
        self.reason = reason
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case kind, code, signal, reason, detail
        case coreDumped = "core_dumped"
    }
}
