public import Foundation
import os

/// A native sheet that waits on the person, shown as an open Feed confirm request while it waits, so it
/// sits in the Feed's pinned Needs you (and whatever Home and the iPhone read from the Feed). The
/// sheet stays the only place its real answer is given: a Feed answer can only cancel the sheet
/// (`confirmed: false`) or bring this Mac's app forward to answer it (`confirmed: true`). First user:
/// the share consent sheet (#30263, #30550), whose allow needs a proof this kind cannot carry.
///
/// One instance per sheet: ``open(_:key:expiresInMs:)`` posts once, ``close()`` withdraws it once
/// (the sheet was answered or timed out), whichever order they run in.
@MainActor
public final class FeedPendingConfirm {
    /// One feed call to the API Worker as the signed-in person (the App's `FeedService.call`).
    public typealias Owner = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// What the request shows: the sheet's title and text, its "bring the Mac forward" label and its
    /// cancel label.
    public struct Request: Sendable, Equatable {
        public var title: String
        public var statement: String
        public var confirmLabel: String
        public var cancelLabel: String

        public init(title: String, statement: String, confirmLabel: String, cancelLabel: String) {
            self.title = title
            self.statement = statement
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
        }
    }

    private let owner: Owner
    public private(set) var item: String?
    private var closed = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "feed.pending-confirm")

    public init(owner: @escaping Owner) {
        self.owner = owner
    }

    /// The `feed.post` op for `request` under dedupe and idempotency key `key`; it lapses with the sheet.
    public static func postBody(_ request: Request, key: String, expiresInMs: Int) -> [String: Any] {
        let params: [String: Any] = [
            "type": "request",
            "kind": "confirm",
            "title": String(request.title.prefix(200)),
            "prompt": [
                "statement": String(request.statement.prefix(2000)),
                "confirm_label": String(request.confirmLabel.prefix(40)),
                "cancel_label": String(request.cancelLabel.prefix(40)),
            ],
            "dedupe_key": String(key.prefix(200)),
            "expires_in_ms": max(expiresInMs, 10_000),
            "poster": ["kind": "app", "label": "cmux"],
        ]
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    /// A closed item's answer: true asks to bring the Mac forward, false to cancel the sheet; nil while
    /// it is open or without an answer.
    public nonisolated static func confirmed(_ item: FeedItem) -> Bool? {
        guard item.state != .open, let answer = item.answer, case let .confirm(confirmed) = answer.value else { return nil }
        return confirmed
    }

    /// Posts `request`; the item id, or nil when it was not posted (or closed first).
    @discardableResult
    public func open(_ request: Request, key: String, expiresInMs: Int) async -> String? {
        guard !closed, item == nil else { return nil }
        do {
            let reply = try await owner("v1/ops", Self.postBody(request, key: key, expiresInMs: expiresInMs))
            guard let id = ((reply["value"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String else { return nil }
            item = id
            // The sheet ended while the post was in flight: withdraw it now.
            if closed { await cancel(id) }
            return closed ? nil : id
        } catch {
            logger.error("a pending confirm was not posted to the Feed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The sheet ended (answered, declined or timed out): the request is withdrawn once.
    public func close() async {
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
