import Foundation
import os

extension NewFrontendBrowserTabRequest {
    /// How long a keyed create asks again after a missed reply deadline.
    public static let lateReplyBudget: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// Sends the create on `connection`. cmux-tui answers it after the tab's
    /// record is durable on disk (a full device flush). Under heavy disk load
    /// that took longer than the 2 s request deadline: the request failed, the
    /// late reply was dropped, and the app never opened the page of the tab
    /// the daemon made. A daemon with `frontend-browser-tab-keys-v1` gets an
    /// idempotency key (derived from the action's key when it has one), and a
    /// missed deadline, a lost connection or a reconnect asks again with the
    /// same key until ``lateReplyBudget`` passes. cmux-tui makes keyed
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
        // The budget runs on the clock the waits use (tests inject one).
        let elapsed = Self.stopwatch(connection.clock)
        // wakeup-allow: deadline: each pass waits for one reply or its deadline, or for the next ready connection; it ends at the budget, on a reply, on close or on another error
        while true {
            let tried = connection.ready?.serial
            do {
                return try await connection.request(keyed)
            } catch let error as DaemonError where Self.asksAgain(after: error) && !Task.isCancelled {
                let left = Self.lateReplyBudget - elapsed()
                guard left > .zero else { throw error }
                Self.logger.info("\(Self.command, privacy: .public): \(String(describing: error), privacy: .public); asking again with its key")
                // A missed deadline already waited a whole deadline. A lost or absent connection fails at once:
                // ask again when a newer connection is ready, never on a timer (closed for good: fail now).
                if case .timedOut = error { continue }
                guard await connection.untilReady(after: tried, within: left) else { throw error }
            }
        }
    }

    /// The time on `clock` since this call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> () -> Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    /// The reply may still come (or the tab may exist) after these: the same key is safe to send again.
    private static func asksAgain(after error: DaemonError) -> Bool {
        switch error {
        case .timedOut, .connectionClosed, .notConnected: true
        default: false
        }
    }
}
