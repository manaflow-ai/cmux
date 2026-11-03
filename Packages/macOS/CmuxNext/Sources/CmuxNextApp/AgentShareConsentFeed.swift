import CmuxNextDaemonService
import CmuxNextFeed
import Foundation
import os

/// The share consent sheet (#30263, #30550) as an open Feed request while it waits, so it sits in
/// the Feed's pinned Needs you (and whatever Home and the iPhone read from the Feed). The sheet
/// stays the only place a link is allowed: a Feed answer can only decline it (`confirmed: false`),
/// or bring this Mac's app forward to answer it (`confirmed: true`, "Show on Mac"). An allow from
/// another device needs a proof this kind cannot carry, so the Feed never allows a link.
///
/// One instance per sheet: ``open(_:key:)`` posts once, ``close()`` withdraws it once (the sheet was
/// answered or timed out), whichever order they run in.
@MainActor
final class AgentShareConsentFeed {
    /// One feed call to the API Worker as the signed-in person (``FeedService/call(_:_:team:)``).
    typealias Owner = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// What a Feed answer asks the sheet to do.
    enum FeedAnswer: Equatable {
        /// "Don't share" on another device: the sheet closes as a decline.
        case decline
        /// "Show on Mac": the app comes forward so the person answers the sheet.
        case show
    }

    private let owner: Owner
    private(set) var item: String?
    private var closed = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-share.consent-feed")

    init(owner: @escaping Owner) {
        self.owner = owner
    }

    /// The `feed.post` op for `ask` under dedupe and idempotency key `key`; it lapses with the sheet.
    static func postBody(_ ask: AgentShareConsentAsk, key: String, expiresInMs: Int) -> [String: Any] {
        let params: [String: Any] = [
            "type": "request",
            "kind": "confirm",
            "title": String(ask.title.prefix(200)),
            "prompt": [
                "statement": String(ask.lines.joined(separator: " ").prefix(2000)),
                "confirm_label": String(ask.showOnMacTitle.prefix(40)),
                "cancel_label": String(ask.declineTitle.prefix(40)),
            ],
            "dedupe_key": String(key.prefix(200)),
            "expires_in_ms": max(expiresInMs, 10_000),
            "poster": ["kind": "app", "label": "cmux"],
        ]
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    /// What a closed item's answer asks of the sheet; nil while it is open or without an answer.
    nonisolated static func answer(of item: FeedItem) -> FeedAnswer? {
        guard item.state != .open, let answer = item.answer, case let .confirm(confirmed) = answer.value else { return nil }
        return confirmed ? .show : .decline
    }

    /// Posts the request for `ask`; the item id, or nil when it was not posted (or closed first).
    @discardableResult
    func open(_ ask: AgentShareConsentAsk, key: String, expiresInMs: Int) async -> String? {
        guard !closed, item == nil else { return nil }
        do {
            let reply = try await owner("v1/ops", Self.postBody(ask, key: key, expiresInMs: expiresInMs))
            guard let id = ((reply["value"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String else { return nil }
            item = id
            // The sheet ended while the post was in flight: withdraw it now.
            if closed { await cancel(id) }
            return closed ? nil : id
        } catch {
            logger.error("share consent: the Feed request was not posted: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The sheet ended (answered, declined or timed out): the request is withdrawn once.
    func close() async {
        guard !closed else { return }
        closed = true
        if let item { await cancel(item) }
    }

    private func cancel(_ id: String) async {
        let body: [String: Any] = ["op": "feed.cancel", "params": ["item": id, "reason": "answered_elsewhere"],
                                   "idempotency_key": "cancel:\(id)", "origin": "script"]
        _ = try? await owner("v1/ops", body)
    }
}
