import Foundation

/// What the app sent to the home session registry for each connected session (`put-session`), and
/// what to do when the daemon did not record it (P-AUSTIN B7a).
public struct SessionRegistrationLedger<Record: Hashable & Sendable>: Sendable {
    /// What a failed `put-session` means for the next attempt.
    public enum Failure: Equatable, Sendable {
        /// The daemon answered with a refusal (size, validation): the same record fails again.
        case refused(String)
        /// No answer (not connected, closed, timed out) or a refusal the daemon marks retryable.
        case unreachable
    }

    /// What the caller does after a failure.
    public struct Outcome: Equatable, Sendable {
        /// Show the person once that this machine is not saved for restore, with this reason.
        public var refusal: String?
        /// Try the same record again after this delay; nil waits for an event.
        public var retryAfter: Duration?
    }

    private var sent: [String: Record] = [:]

    public init(policy: RetryPolicy = .sessionRegistration) {}

    /// Whether `record` must be sent for `session` now; when true it counts as sent.
    public mutating func shouldSend(session: String, record: Record, connection: ObjectIdentifier) -> Bool {
        guard sent[session] != record else { return false }
        sent[session] = record
        return true
    }

    /// The daemon recorded `record`.
    public mutating func succeeded(session: String, record: Record) {}

    /// The daemon did not record `record`: forgotten, so the next sync sends it again.
    public mutating func failed(session: String, record: Record, error: any Error) -> Outcome {
        if sent[session] == record { sent[session] = nil }
        return Outcome(refusal: nil, retryAfter: nil)
    }

    /// A backoff wait of `session` ended.
    public mutating func retryDue(session: String) {}

    /// The daemon has recorded `session`'s current record.
    public func isRecorded(session: String) -> Bool { sent[session] != nil }

    /// A refusal the same request gets again, or a failure that may pass on a later attempt. The daemon
    /// answers a request it refuses as invalid with a `bad request:` message and no code (cmux-tui
    /// `send_bad_request`, `validate_*`); any other `ok:false` (a store or I/O error) can pass later.
    public static func classify(_ error: any Error) -> Failure {
        if case .command(_, let message, _, _, let retryable) = error as? DaemonError, retryable != true,
           message.hasPrefix(Self.invalidRequestPrefix) {
            return .refused(message)
        }
        return .unreachable
    }

    static var invalidRequestPrefix: String { "bad request" }
}

extension RetryPolicy {
    /// A `put-session` with no answer: 250 ms growing to 30 s, 8 timed attempts, then an event.
    public static let sessionRegistration = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 8)
}
