public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os

/// Sends each connected session's record to the home session registry (`put-session`) and acts
/// on the answer through a ``SessionRegistrationLedger`` (P-AUSTIN B7a): a refusal is shown once
/// (`notice`, the person's only sign that the machine is not saved for restore) and the same record
/// is not sent again until it changes or the home connection is new; a failure with no answer is
/// sent again after the ledger's backoff, which then waits for an event. The app only builds the
/// records, calls ``submit(session:record:machine:connection:send:)`` from its sync and shows the
/// notice; ``onRetryDue`` asks it to sync again.
@MainActor
public final class SessionRegistration<Record: Hashable & Sendable> {
    private var ledger: SessionRegistrationLedger<Record>
    private var retries: [String: DemandTimer] = [:]
    /// Shows one localized message for `session`; false when nothing could show it (no window).
    private let notice: @MainActor (_ session: String, _ message: String) -> Bool
    /// Refusal notices not shown yet (no window), per session: shown at the next submit.
    private var pendingNotices: [String: String] = [:]
    private var stopped = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "session-registration")
    /// Called when a backoff ends: the owner syncs, which submits the record again.
    public var onRetryDue: (@MainActor () -> Void)?

    /// `policy` spaces the retries of a send with no answer (the app passes
    /// `RetryPolicy.sessionRegistration`); `notice` shows one localized message (a toast) for a refused
    /// record of a session and returns whether it was shown.
    public init(policy: RetryPolicy, notice: @escaping @MainActor (_ session: String, _ message: String) -> Bool) {
        ledger = SessionRegistrationLedger(policy: policy)
        self.notice = notice
    }

    /// The DemandTimers cancel themselves when released; an isolated deinit of a generic main-actor
    /// class crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Sends `record` for `session` with `send` unless the ledger holds it already (sent, recorded,
    /// refused on this connection, or backing off). `epoch` is the home store's connection epoch:
    /// a new one (the daemon restarted or the connection was made again) sends every record again.
    /// `machine` names it in a notice. Returns the send's task, nil when nothing is sent.
    @discardableResult
    public func submit(session: String, record: Record, machine: String?, epoch: Int,
                       send: @escaping @Sendable () async throws -> Void) -> Task<Void, Never>? {
        guard !stopped else { return nil }
        showPendingNotices()
        let link = SessionRegistrationConnection(generation: UInt64(truncatingIfNeeded: epoch))
        guard let token = ledger.begin(session: session, record: record, connection: link) else { return nil }
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
        pendingNotices = pendingNotices.filter { sessions.contains($0.key) }
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
            if ledger.isRecorded(session: session) { pendingNotices[session] = nil }
            return
        }
        logger.error("put-session \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        let outcome = ledger.failed(session: session, token: token, failure: SessionRegistrationLedger<Record>.classify(error))
        if let reason = outcome.refusal {
            pendingNotices[session] = Self.notSavedForRestore(machine: machine, reason: reason)
            showPendingNotices()
        }
        guard let delay = outcome.retryAfter else {
            // No answer and the timed retries are spent: the record waits for an event (a changed
            // record or a new connection epoch), so the person sees that it is not saved (R9 R-L5).
            if outcome.refusal == nil, ledger.isWaitingForEvent(session: session) {
                pendingNotices[session] = Self.notSavedForRestore(machine: machine, reason: String(describing: error))
                showPendingNotices()
            }
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

    /// Shows the notices no window could show yet (the owner calls it when a window appears).
    public func showPendingNotices() {
        for (session, message) in pendingNotices where notice(session, message) {
            pendingNotices[session] = nil
        }
    }

    // Keys live in Resources/SessionRegistration.xcstrings.
    /// The home daemon refused to record a connected machine: the next launch does not restore it.
    nonisolated static func notSavedForRestore(machine: String?, reason: String) -> String {
        guard let machine, !machine.isEmpty else {
            return String(format: String(localized: "sessionRegistration.notSaved.unnamed",
                                         defaultValue: "This machine was not saved for restore: %@",
                                         table: "SessionRegistration", bundle: .module), reason)
        }
        return String(format: String(localized: "sessionRegistration.notSaved",
                                     defaultValue: "%1$@ was not saved for restore: %2$@",
                                     table: "SessionRegistration", bundle: .module), machine, reason)
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
