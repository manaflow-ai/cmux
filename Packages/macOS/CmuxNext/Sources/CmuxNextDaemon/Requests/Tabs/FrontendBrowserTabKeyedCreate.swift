import CmuxNextCompat
import Foundation
import os

extension NewFrontendBrowserTabRequest {
    /// How long a keyed create asks again after a missed reply deadline (a lost link waits for the reconnect, until the
    /// request deadline, instead).
    public static let lateReplyBudget: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// Sends the create on `connection`. cmux-tui answers it after the tab's
    /// record is durable on disk (a full device flush). Under heavy disk load
    /// that took longer than the 2 s request deadline: the request failed, the
    /// late reply was dropped, and the app never opened the page of the tab
    /// the daemon made. A daemon with `frontend-browser-tab-keys-v1` gets an
    /// idempotency key (derived from the action's key when it has one). A
    /// missed reply deadline asks again with the same key until
    /// ``lateReplyBudget`` passes. A lost connection waits for the connection's
    /// connected event (its reconnect) and sends once more with the same key
    /// when the link is up, or fails at the request deadline; it never asks
    /// again sooner (#35878: an immediate re-send held the connection actor for
    /// the whole budget, so the reconnect could not run). cmux-tui makes keyed
    /// creates one at a time and answers a repeated key with the tab the
    /// first request made (`replayed`), so a late commit makes one tab.
    /// Callers that make several tabs in one action make them in order, so
    /// each derived key names the same tab when the action is retried.
    func send(on connection: isolated DaemonConnection) async throws -> Response {
        guard connection.identity?.supports(DaemonCapability.frontendBrowserTabKeys.rawValue) == true else {
            return try await connection.request(self)
        }
        var keyed = self
        keyed.idempotencyKey = (DaemonCommandScope.current?.nextDerivedUUID("frontend-browser-tab") ?? UUID()).uuidString.lowercased()
        let started = ContinuousClock.now
        let giveUp = started + Self.lateReplyBudget, linkDeadline = started + (connection.configuration.requestTimeout ?? Self.lateReplyBudget)
        // wakeup-allow: one send per pass: a missed reply asks again until the budget; a lost link waits for the connection's
        // connected event (its reconnect ending), at most until the request deadline, and is never sent again sooner (#35878)
        while true {
            do {
                return try await connection.request(keyed)
            } catch let error as DaemonError where Self.asksAgain(after: error) && !Task.isCancelled {
                if case .timedOut = error {
                    guard ContinuousClock.now < giveUp else { throw error }
                } else {
                    guard ContinuousClock.now < linkDeadline, await Self.linkUp(on: connection, until: linkDeadline) else { throw error }
                }
                Self.logger.info("\(Self.command, privacy: .public): \(String(describing: error), privacy: .public); asking again with its key")
            }
        }
    }

    /// Whether `connection`'s link is up, after waiting for its reconnect to end (at its connected event, a close or a
    /// failure for good), at most until `deadline`. A request failed by a drop can run before the connection learns of the
    /// drop and starts its reconnect in its turn: that turn runs first.
    private static func linkUp(on connection: isolated DaemonConnection, until deadline: ContinuousClock.Instant) async -> Bool {
        if connection.reconnectTask == nil, !connection.isReady { await Task.yield() }
        if let reconnect = connection.reconnectTask { await LinkWait.reconnected(reconnect, until: deadline) }
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

/// One wait of a keyed create for its connection's reconnect (``NewFrontendBrowserTabRequest/send(on:)``), bounded by the
/// request deadline: it ends once, at whichever comes first.
private final class LinkWait: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    private init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = Mutex(continuation) }

    private func end() {
        let pending = continuation.withLock { pending -> CheckedContinuation<Void, Never>? in
            let taken = pending
            pending = nil
            return taken
        }
        pending?.resume()
    }

    /// Returns once `reconnect` ended or `deadline` passed.
    static func reconnected(_ reconnect: Task<Void, Never>, until deadline: ContinuousClock.Instant) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let wait = LinkWait(done)
            // task-owner: this wait; its one deadline, cancelled when the reconnect ends first
            let bound = Task {
                // wakeup-allow: one-shot bound of one wait (the request deadline), not a retry pause
                try? await Task.sleep(until: deadline, clock: .continuous)
                wait.end()
            }
            // task-owner: this wait; ends with the connection's reconnect loop
            Task {
                await reconnect.value
                bound.cancel()
                wait.end()
            }
        }
    }
}
