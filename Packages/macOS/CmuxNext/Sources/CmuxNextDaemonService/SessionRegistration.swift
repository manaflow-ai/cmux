public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os

/// Sends each connected session's record to the home session registry (`put-session`) and acts
/// on the answer through a ``SessionRegistrationLedger`` (P-AUSTIN B7a): a refused record is not
/// sent again until it changes or the home connection is new; a failure with no answer is sent
/// again after the ledger's backoff, which then waits for an event. Neither shows the person
/// anything (there is nothing they can do about it): each goes to the log and to ``refusedCount``
/// and ``unansweredCount``. The app only builds the records and calls
/// ``submit(session:record:machine:epoch:send:)`` from its sync; ``onRetryDue`` asks it to sync again.
@MainActor
public final class SessionRegistration<Record: Hashable & Sendable> {
    private var ledger: SessionRegistrationLedger<Record>
    private var retries: [String: DemandTimer] = [:]
    private var stopped = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "session-registration")
    /// Records the home daemon refused since launch (each is logged with the daemon's text).
    public private(set) var refusedCount = 0
    /// Records whose send got no answer and whose timed retries ran out since launch.
    public private(set) var unansweredCount = 0
    /// Called when a backoff ends: the owner syncs, which submits the record again.
    public var onRetryDue: (@MainActor () -> Void)?

    /// `policy` spaces the retries of a send with no answer (the app passes `RetryPolicy.sessionRegistration`).
    public init(policy: RetryPolicy) {
        ledger = SessionRegistrationLedger(policy: policy)
    }

    /// The DemandTimers cancel themselves when released; an isolated deinit of a generic main-actor
    /// class crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Sends `record` for `session` with `send` unless the ledger holds it already (sent, recorded,
    /// refused on this connection, or backing off). `epoch` is the home store's connection epoch:
    /// a new one (the daemon restarted or the connection was made again) sends every record again.
    /// `machine` names it in the log. Returns the send's task, nil when nothing is sent.
    @discardableResult
    public func submit(session: String, record: Record, machine: String?, epoch: Int,
                       send: @escaping @Sendable () async throws -> Void) -> Task<Void, Never>? {
        guard !stopped else { return nil }
        let link = SessionRegistrationConnection(generation: UInt64(truncatingIfNeeded: epoch))
        let token = ledger.begin(session: session, record: record, connection: link)
        guard let token else { return nil }
        // task-owner: one put-session; its answer goes to the ledger on the main actor
        return Task { [weak self] in
            do {
                try await send()
                self?.answered(session: session, token: token, machine: machine, error: nil)
            } catch {
                self?.answered(session: session, token: token, machine: machine, error: error)
            }
        }
    }

    /// Forgets the sessions not in `sessions` (gone from the machine list) and their pending retries.
    public func retain(sessions: Set<String>) {
        ledger.retain(sessions: sessions)
        for (session, timer) in retries where !sessions.contains(session) {
            timer.cancel()
            retries[session] = nil
        }
    }

    public func stop() {
        stopped = true
        for timer in retries.values { timer.cancel() }
        retries.removeAll()
    }

    private func answered(session: String, token: UInt64, machine: String?, error: (any Error)?) {
        guard !stopped else { return }
        guard let error else {
            ledger.succeeded(session: session, token: token)
            return
        }
        logger.error("put-session \(session, privacy: .public) (\(machine ?? "unnamed", privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        let outcome = ledger.failed(session: session, token: token, failure: SessionRegistrationLedger<Record>.classify(error))
        if outcome.refusal != nil { refusedCount += 1 }
        guard let delay = outcome.retryAfter else {
            // No answer and the timed retries are spent: the record waits for an event (a changed
            // record or a new connection epoch).
            if outcome.refusal == nil, ledger.isWaitingForEvent(session: session) { unansweredCount += 1 }
            return
        }
        let timer = retries[session] ?? DemandTimer(owner: "SessionRegistration.retry")
        retries[session] = timer
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.ledger.retryDue(session: session)
            self.onRetryDue?()
        }
    }
}

/// What the app sends for one session (`put-session`): its name, sorted capabilities and transport.
/// A plain value, compared by the ledger.
nonisolated public struct SessionRegistrationRecord: Hashable, Sendable {
    /// The machine's display name; a renamed machine is sent again.
    public var machineName: String?
    public var sessionName: String?
    public var capabilities: [String]
    public var transport: JSONValue

    public init(machineName: String?, sessionName: String?, capabilities: [String], transport: JSONValue) {
        self.machineName = machineName
        self.sessionName = sessionName
        self.capabilities = capabilities
        self.transport = transport
    }
}
