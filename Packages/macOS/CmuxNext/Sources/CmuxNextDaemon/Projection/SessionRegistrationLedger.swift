import Foundation

/// What the app sent to the home session registry for each connected session (`put-session`), and
/// what to do when the daemon did not record it (P-AUSTIN B7a).
///
/// - A refusal (the daemon answered `ok:false` and did not mark it retryable: a size or validation
///   error) fails the same way for the same record, so the record is not sent again until it
///   changes or the home daemon restarts (a new connection). The caller shows the reason once per
///   refused record: a machine that is not in the registry is not restored at the next launch.
/// - A failure with no answer (not connected, closed, timed out, busy) retries the same record
///   with ``RetryPacer``'s capped, jittered backoff; when its timed retries are spent, the record
///   waits for an event (a change of the record or a new connection).
/// - An answer for a record that was replaced while it was in flight changes nothing.
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

    private enum State: Sendable {
        /// Sent, no answer yet.
        case inFlight
        case recorded
        /// Refused on that connection; not sent again on it.
        case refused
        /// No answer; sent again when ``retryDue(session:)`` comes (`waitingForEvent`: never on a timer).
        case backingOff(waitingForEvent: Bool)
        /// The backoff ended: send at the next sync.
        case due
    }

    private struct Entry: Sendable {
        var record: Record
        var connection: ObjectIdentifier
        var state: State
        var pacer: RetryPacer
    }

    private let policy: RetryPolicy
    private var entries: [String: Entry] = [:]
    /// The refusals already shown, per session (the reason shows once per refused record).
    private var shownRefusals: [String: Record] = [:]

    public init(policy: RetryPolicy = .sessionRegistration) {
        self.policy = policy
    }

    /// Whether `record` must be sent for `session` on `connection` now; when true it counts as in flight.
    public mutating func shouldSend(session: String, record: Record, connection: ObjectIdentifier) -> Bool {
        if var entry = entries[session], entry.record == record, entry.connection == connection {
            switch entry.state {
            case .inFlight, .recorded, .refused, .backingOff: return false
            case .due:
                entry.state = .inFlight
                entries[session] = entry
                return true
            }
        }
        // A new or changed record, or a new connection (the daemon restarted): send it, with a new backoff.
        entries[session] = Entry(record: record, connection: connection, state: .inFlight, pacer: RetryPacer(policy))
        return true
    }

    /// The daemon recorded `record`.
    public mutating func succeeded(session: String, record: Record) {
        guard var entry = entries[session], entry.record == record else { return }
        entry.state = .recorded
        entry.pacer.reset()
        entries[session] = entry
        shownRefusals[session] = nil
    }

    /// The daemon did not record `record` (`error` from the request).
    public mutating func failed(session: String, record: Record, error: any Error) -> Outcome {
        failed(session: session, record: record, failure: Self.classify(error))
    }

    /// The daemon did not record `record` (`failure`: ``classify(_:)`` of the request's error).
    public mutating func failed(session: String, record: Record, failure: Failure) -> Outcome {
        guard var entry = entries[session], entry.record == record else { return Outcome(refusal: nil, retryAfter: nil) }
        switch failure {
        case .refused(let reason):
            entry.state = .refused
            entries[session] = entry
            guard shownRefusals[session] != record else { return Outcome(refusal: nil, retryAfter: nil) }
            shownRefusals[session] = record
            return Outcome(refusal: reason, retryAfter: nil)
        case .unreachable:
            let delay = entry.pacer.failed()
            entry.state = .backingOff(waitingForEvent: delay == nil)
            entries[session] = entry
            return Outcome(refusal: nil, retryAfter: delay)
        }
    }

    /// A backoff wait of `session` ended: the next sync sends its record again.
    public mutating func retryDue(session: String) {
        guard var entry = entries[session], case .backingOff(waitingForEvent: false) = entry.state else { return }
        entry.state = .due
        entries[session] = entry
    }

    /// The daemon has recorded `session`'s current record.
    public func isRecorded(session: String) -> Bool {
        if case .recorded = entries[session]?.state { return true }
        return false
    }

    /// A refusal the same request gets again, or a failure that may pass on a later attempt.
    public static func classify(_ error: any Error) -> Failure {
        if case .command(_, let message, _, _, let retryable) = error as? DaemonError, retryable != true {
            return .refused(message)
        }
        return .unreachable
    }
}

extension RetryPolicy {
    /// A `put-session` with no answer: 250 ms growing to 30 s, 8 timed attempts, then an event.
    public static let sessionRegistration = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 8)
}
