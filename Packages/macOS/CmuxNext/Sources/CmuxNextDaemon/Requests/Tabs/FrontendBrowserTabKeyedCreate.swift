import Foundation
import os

extension NewFrontendBrowserTabRequest {
    /// How long a keyed create asks again after a lost connection or a reconnect. A missed reply deadline (30 s by
    /// default since #35075) comes after it and ends the create; a connection set to a shorter deadline asks again after one.
    public static let lateReplyBudget: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// Sends the create on `connection`. cmux-tui answers it after the tab's
    /// record is durable on disk (a full device flush). Under heavy disk load
    /// that took longer than the request deadline (2 s then; 30 s since #35075,
    /// ``DaemonConnection/defaultRequestTimeout``): the request failed, the
    /// late reply was dropped, and the app never opened the page of the tab
    /// the daemon made. A daemon with `frontend-browser-tab-keys-v1` gets an
    /// idempotency key (derived from the action's key when it has one), and a
    /// lost connection or a reconnect asks again with the same key until
    /// ``lateReplyBudget`` passes (a missed 30 s reply deadline comes after that
    /// 10 s budget, so it ends the create). cmux-tui makes keyed
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
        let giveUp = ContinuousClock.now + Self.lateReplyBudget
        // wakeup-allow: each pass waits for one reply or its deadline; the keyed retry ends at the budget, on a reply, or on another error
        while true {
            do {
                return try await connection.request(keyed)
            } catch let error as DaemonError where Self.asksAgain(after: error) && ContinuousClock.now < giveUp && !Task.isCancelled {
                Self.logger.info("\(Self.command, privacy: .public): \(String(describing: error), privacy: .public); asking again with its key")
            }
        }
    }

    /// The reply may still come (or the tab may exist) after these: the same key is safe to send again.
    private static func asksAgain(after error: DaemonError) -> Bool {
        switch error {
        case .timedOut, .connectionClosed, .notConnected: true
        default: false
        }
    }
}
