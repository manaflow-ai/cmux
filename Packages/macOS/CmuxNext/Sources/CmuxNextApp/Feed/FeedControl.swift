import CmuxNextControl
import CmuxNextFeed
import CmuxNextSettings
import Foundation

/// Control methods for local feed adapters (plans/cmux-next/feed.md 8.1) and
/// verification. The app posts as the signed-in user: a hook process in a
/// terminal has no account token, and it can only post and cancel here, never
/// answer (answers come from the user's own clients with origin user).
///
/// - `feed.request {post: <feed.post params>, idempotency_key, wait_seconds?}`:
///   posts, then waits up to `wait_seconds` (at most 120) for the owner to
///   close the item; replies `{item, timed_out}` with the owner's stored item.
/// - `feed.cancel {item, reason?, note?}`: the poster withdraws its item
///   (`answered_elsewhere` when the user answered in the terminal).
/// - `debug.feed`: sign-in, connection, mirror counts.
enum FeedControl {
    static let maxWait = 120

    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .async("feed.request") { [weak services] call in
                let feed = await MainActor.run { services?.feed }
                guard let feed else { throw ControlError(code: "unavailable", message: "feed is not available") }
                return try await request(feed, call.params)
            }.withDeadline(.fixed(.seconds(maxWait + 15))),
            .async("feed.cancel") { [weak services] call in
                let feed = await MainActor.run { services?.feed }
                guard let feed else { throw ControlError(code: "unavailable", message: "feed is not available") }
                return try await cancel(feed, call.params)
            }.withDeadline(.fixed(.seconds(20))),
            .mainActor("debug.feed") { [weak services] _ in
                guard let feed = services?.feed else { return .value(.null) }
                return .value(debug(feed))
            },
        ]
    }

    @MainActor
    static func request(_ feed: FeedService, _ params: [String: JSONValue]) async throws -> JSONValue {
        guard let post = params["post"]?.objectValue else { throw ControlError.invalidParams("feed.request needs `post` (feed.post params)") }
        guard let key = params["idempotency_key"]?.stringValue, !key.isEmpty else { throw ControlError.invalidParams("feed.request needs `idempotency_key`") }
        let wait = min(max(params["wait_seconds"]?.intValue ?? 0, 0), maxWait)
        feed.startIfSignedIn()
        let posted = try await owner(feed, "v1/ops", ["op": "feed.post", "params": JSONValue.object(post).foundationObject, "idempotency_key": key, "origin": "cli"])
        guard let id = ((posted["value"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String else {
            throw ControlError(code: "feed.bad_reply", message: "the owner returned no item")
        }
        if wait > 0 { await feed.waitClosed(id, until: .now + .seconds(wait)) }
        let read = try await owner(feed, "v1/read", ["op": "feed.get", "params": ["item": id]])
        let item = (read["value"] as? [String: Any])?["item"] ?? [:]
        let open = ((item as? [String: Any])?["state"] as? String) == "open"
        return .object(["item": JSONValue(foundation: item) ?? .null, "timed_out": .bool(wait > 0 && open)])
    }

    @MainActor
    static func cancel(_ feed: FeedService, _ params: [String: JSONValue]) async throws -> JSONValue {
        guard let item = params["item"]?.stringValue else { throw ControlError.invalidParams("feed.cancel needs `item`") }
        var body: [String: Any] = ["item": item]
        if let reason = params["reason"]?.stringValue { body["reason"] = reason }
        if let note = params["note"]?.stringValue { body["note"] = note }
        let key = params["idempotency_key"]?.stringValue ?? "cancel:\(item):\(body["reason"] as? String ?? "poster")"
        let reply = try await owner(feed, "v1/ops", ["op": "feed.cancel", "params": body, "idempotency_key": key, "origin": "cli"])
        return JSONValue(foundation: reply["value"] ?? [:]) ?? .null
    }

    @MainActor
    private static func owner(_ feed: FeedService, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        do {
            return try await feed.call(path, body)
        } catch FeedServiceError.signedOut {
            throw ControlError(code: "feed.signed_out", message: "sign in to cmux to use the feed")
        } catch let FeedServiceError.owner(code, message) {
            throw ControlError(code: code, message: message)
        } catch {
            throw ControlError(code: "owner.unreachable", message: String(describing: error))
        }
    }

    @MainActor
    static func debug(_ feed: FeedService) -> JSONValue {
        let connection: String = switch feed.connection {
        case .connecting: "connecting"
        case .connected: "connected"
        case let .disconnected(reason): "disconnected: \(reason)"
        }
        let items = feed.model.visibleItems
        return .object([
            "signed_in": .bool(feed.isSignedIn),
            "api": .string(feed.apiBaseURL.absoluteString),
            "connection": .string(connection),
            "items": .number(Double(items.count)),
            "open_requests": .number(Double(items.filter(\.isOpenRequest).count)),
            "unread": .number(Double(items.filter(\.isUnread).count)),
        ])
    }
}
