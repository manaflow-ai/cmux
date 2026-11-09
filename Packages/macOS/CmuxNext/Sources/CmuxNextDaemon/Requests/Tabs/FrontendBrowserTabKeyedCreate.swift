import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import os

extension NewFrontendBrowserTabRequest {
    /// How long a keyed create asks again: while its link is down (then also at most the request deadline), and after
    /// a missed reply deadline that came before it (the default deadline, 30 s since #35075, comes after it and ends the
    /// create; a connection set to a shorter deadline asks again after one). Its last send then has one request deadline
    /// more, which `ActionRunLimit.keyedCreate` (this budget plus one request deadline) covers.
    public static let lateReplyBudget: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// Sends the create on `connection`. cmux-tui answers it after the tab's
    /// record is durable on disk (a full device flush). Under heavy disk load
    /// that took longer than the request deadline (2 s then; 30 s since #35075,
    /// ``DaemonConnection/defaultRequestTimeout``): the request failed, the
    /// late reply was dropped, and the app never opened the page of the tab
    /// the daemon made. A daemon with `frontend-browser-tab-keys-v1` gets an
    /// idempotency key (derived from the action's key when it has one). A
    /// missed reply deadline asks again with the same key until
    /// ``lateReplyBudget`` passes (the default 30 s deadline comes after that
    /// 10 s budget, so it ends the create). A lost link waits for the
    /// connection's reconnect (its connected event) and sends once more with
    /// the same key when the link is up; the wait ends at the request deadline
    /// or the budget, whichever comes first, or when the create is cancelled.
    /// It never asks again sooner (#35878: an immediate re-send held the
    /// connection actor for the whole budget, so the reconnect could not run).
    /// cmux-tui makes keyed creates one at a time and answers a repeated key
    /// with the tab the first request made (`replayed`), so a late commit makes
    /// one tab. Callers that make several tabs in one action make them in
    /// order, so each derived key names the same tab when the action is retried.
    func send(on connection: isolated DaemonConnection) async throws -> Response {
        guard connection.identity?.supports(DaemonCapability.frontendBrowserTabKeys.rawValue) == true else {
            return try await connection.request(self)
        }
        var keyed = self
        keyed.idempotencyKey = (DaemonCommandScope.current?.nextDerivedUUID("frontend-browser-tab") ?? UUID()).uuidString.lowercased()
        let started = ContinuousClock.now
        let giveUp = started + Self.lateReplyBudget
        let linkDeadline = min(giveUp, started + (connection.configuration.requestTimeout ?? Self.lateReplyBudget))
        // wakeup-allow: one send per pass: a missed reply asks again until the budget; a lost link waits for its reconnect
        // to end (the connected event), at most until its deadline, and is never sent again sooner (#35878)
        while true {
            do {
                return try await connection.request(keyed)
            } catch let error as DaemonError where Self.asksAgain(after: error) && !Task.isCancelled {
                if case .timedOut = error {
                    guard ContinuousClock.now < giveUp else { throw error }
                } else {
                    guard await Self.linkUp(on: connection, after: error, until: linkDeadline), !Task.isCancelled else { throw error }
                }
                Self.logger.info("\(Self.command, privacy: .public): \(String(describing: error), privacy: .public); asking again with its key")
            }
        }
    }

    /// Whether `connection`'s link is up, after waiting for its reconnects to end (each at its connected event, a close or
    /// a failure for good), at most until `deadline` or the create's cancellation.
    private static func linkUp(on connection: isolated DaemonConnection, after error: DaemonError,
                               until deadline: ContinuousClock.Instant) async -> Bool {
        // The reader fails a request in flight at the drop before it posts the connection's close hop, so that request
        // can run while the connection still reads ready on the closed transport: this turn ends that ready phase as the
        // hop would (the hop then changes nothing), so the reconnect starts now and the create never sends again on the
        // closed transport in a loop that keeps the hop out (review of #35885).
        if let ready = connection.ready, ready.transport.isClosed {
            var detail = error.description
            if case .connectionClosed(let reason) = error { detail = reason }
            connection.transportClosed(serial: ready.serial, reason: .lost(detail))
        }
        // wakeup-allow: each pass parks until one reconnect ends, the deadline or the cancel; a reconnect that connected ends it
        while !connection.isReady, let reconnect = connection.reconnectTask, ContinuousClock.now < deadline, !Task.isCancelled {
            await LinkWait.reconnected(reconnect, until: deadline)
        }
        return connection.isReady
    }

    /// The reply may still come (or the tab may exist) after these: the same key is safe to send again.
    private static func asksAgain(after error: DaemonError) -> Bool {
        switch error {
        case .timedOut, .connectionClosed, .notConnected: true
        default: false
        }
    }
}

/// One wait of a keyed create for its connection's reconnect (``NewFrontendBrowserTabRequest/send(on:)``): it ends once,
/// at the first of the reconnect's end, the deadline and the create's cancellation.
private final class LinkWait: Sendable {
    private enum Phase {
        case waiting
        case parked(CheckedContinuation<Void, Never>)
        case ended
    }

    private let phase = Mutex(Phase.waiting)

    /// Parks `continuation` until ``end()``, or resumes it at once when the wait already ended (a cancel before the park).
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        let ended = phase.withLock { phase -> Bool in
            if case .ended = phase { return true }
            phase = .parked(continuation)
            return false
        }
        if ended { continuation.resume() }
    }

    private func end() {
        let parked = phase.withLock { phase -> CheckedContinuation<Void, Never>? in
            defer { phase = .ended }
            if case .parked(let continuation) = phase { return continuation }
            return nil
        }
        parked?.resume()
    }

    /// Returns once `reconnect` ended, `deadline` passed or the calling task is cancelled.
    static func reconnected(_ reconnect: Task<Void, Never>, until deadline: ContinuousClock.Instant) async {
        let wait = LinkWait()
        let bound = DemandTimer(owner: "NewFrontendBrowserTabRequest.linkWait")
        bound.schedule(after: ContinuousClock.now.duration(to: deadline)) { wait.end() }
        // task-owner: this wait; ends with the connection's reconnect loop (a wait that ended first leaves it until then)
        Task {
            await reconnect.value
            wait.end()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait.park($0) }
        } onCancel: {
            wait.end()
        }
        bound.cancel()
    }
}
