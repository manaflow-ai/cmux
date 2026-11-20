import Foundation

/// What the app sent to the home session registry for each connected session (`put-session`), and
/// what to do when the daemon did not record it (P-AUSTIN B7a).
///
/// - A refusal (a `bad request:` answer the daemon does not mark retryable: a size or validation
///   error) fails the same way for the same record, so the record is not sent again until it
///   changes or the home connection is new (a new connection epoch: the daemon restarted). The
///   caller shows the reason once per refused record: a machine that is not in the registry is not
///   restored at the next launch.
/// - A failure with no answer (not connected, closed, timed out, busy) retries the same record
///   with ``RetryPacer``'s capped, jittered backoff; when its timed retries are spent, the record
///   waits for an event (a change of the record or a new connection epoch), and the caller shows it.
/// - An answer for a record that was replaced while it was in flight changes nothing.
public struct SessionRegistrationLedger<Record: Hashable & Sendable>: Sendable {
    /// What a failed `put-session` means for the next attempt.
    public enum Failure: Equatable, Sendable {
        /// A `bad request:` answer (size, validation): the same record fails again.
        case refused(String)
        /// No answer (not connected, closed, timed out), a store error, or a retryable refusal.
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
        var connection: SessionRegistrationConnection
        var state: State
        var pacer: RetryPacer
        /// The send in flight or last answered; an answer with another token is stale.
        var token: UInt64
    }

    private let policy: RetryPolicy
    private var entries: [String: Entry] = [:]
    /// The refusals already shown, per session (the reason shows once per refused record).
    private var shownRefusals: [String: Record] = [:]
    private var nextToken: UInt64 = 0

    public init(policy: RetryPolicy = .sessionRegistration) {
        self.policy = policy
    }

    /// Whether `record` must be sent for `session` on `connection` now; when true it counts as in flight.
    mutating func shouldSend(session: String, record: Record, connection: SessionRegistrationConnection) -> Bool {
        begin(session: session, record: record, connection: connection) != nil
    }

    /// ``shouldSend(session:record:connection:)`` with an object's identity as the connection
    /// (``SessionRegistrationConnection/init(object:)``).
    mutating func shouldSend(session: String, record: Record, connection object: ObjectIdentifier) -> Bool {
        shouldSend(session: session, record: record, connection: SessionRegistrationConnection(object: object))
    }

    /// ``shouldSend(session:record:connection:)`` that returns the send's token, or nil when nothing is
    /// sent. `connection` identifies the home connection (the owner's generation counter): a new one
    /// sends every record again.
    public mutating func begin(session: String, record: Record, connection: SessionRegistrationConnection) -> UInt64? {
        nextToken &+= 1
        if var entry = entries[session], entry.record == record, entry.connection == connection {
            switch entry.state {
            case .inFlight, .recorded, .refused, .backingOff: return nil
            case .due:
                entry.state = .inFlight
                entry.token = nextToken
                entries[session] = entry
                return nextToken
            }
        }
        // A new or changed record, or a new connection (the daemon restarted): send it, with a new backoff.
        entries[session] = Entry(record: record, connection: connection, state: .inFlight, pacer: RetryPacer(policy),
                                 token: nextToken)
        return nextToken
    }

    /// The daemon recorded the send `token`; an answer to an older send changes nothing.
    public mutating func succeeded(session: String, token: UInt64) {
        guard let entry = entries[session], entry.token == token, case .inFlight = entry.state else { return }
        succeeded(session: session, record: entry.record)
    }

    /// The daemon did not record the send `token`; an answer to an older send changes nothing.
    public mutating func failed(session: String, token: UInt64, failure: Failure) -> Outcome {
        guard let entry = entries[session], entry.token == token, case .inFlight = entry.state else {
            return Outcome(refusal: nil, retryAfter: nil)
        }
        return failed(session: session, record: entry.record, failure: failure)
    }

    /// The refusal of `session` counts as not shown: its notice was dropped before the person saw
    /// it, or taken back, so the same refusal shows again.
    public mutating func forgetShownRefusal(session: String) {
        shownRefusals[session] = nil
    }

    /// Forgets every session not in `sessions` (gone from the machine list): a session that comes back
    /// is sent once again. The refusals already shown are kept here; the owner calls
    /// ``forgetShownRefusal(session:)`` for a gone session whose notice it took back, so that refusal
    /// shows again if the session comes back and is refused again.
    public mutating func retain(sessions: Set<String>) {
        entries = entries.filter { sessions.contains($0.key) }
    }

    /// The daemon recorded `record`.
    mutating func succeeded(session: String, record: Record) {
        guard var entry = entries[session], entry.record == record else { return }
        entry.state = .recorded
        entry.pacer.reset()
        entries[session] = entry
        shownRefusals[session] = nil
    }

    /// The daemon did not record `record` (`error` from the request).
    mutating func failed(session: String, record: Record, error: any Error) -> Outcome {
        failed(session: session, record: record, failure: Self.classify(error))
    }

    /// The daemon did not record `record` (`failure`: ``classify(_:)`` of the request's error).
    mutating func failed(session: String, record: Record, failure: Failure) -> Outcome {
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

    /// The current record of `session` got no answer and its timed retries are spent: only a changed
    /// record or a new connection sends it again.
    public func isWaitingForEvent(session: String) -> Bool {
        if case .backingOff(waitingForEvent: true) = entries[session]?.state { return true }
        return false
    }

    /// The daemon has recorded `session`'s current record.
    public func isRecorded(session: String) -> Bool {
        if case .recorded = entries[session]?.state { return true }
        return false
    }

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

/// The home connection a record went to: the home store's connection epoch, compared by value. A
/// `DaemonConnection` reconnects in place after a daemon restart, so its epoch, not the object,
/// tells a new connection from the old one.
public struct SessionRegistrationConnection: Hashable, Sendable, ExpressibleByIntegerLiteral {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }

    public init(integerLiteral value: UInt64) {
        generation = value
    }

    /// An object's identity as the connection, for an owner that keeps the object alive as long as
    /// its entries: a freed object's address can be reused by a new one.
    init(object: ObjectIdentifier) {
        generation = UInt64(truncatingIfNeeded: UInt(bitPattern: object))
    }
}
