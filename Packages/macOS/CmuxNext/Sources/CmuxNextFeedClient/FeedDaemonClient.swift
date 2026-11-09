import CmuxNextWakeups
package import CmuxNextDaemon
import Foundation
import os

/// The native callers' side of the daemon's feed client (`feed-client-v1`,
/// plans/cmux-next/feed-page.md 2): the same `feed.*` ops the Feed page calls through its relay,
/// sent on the app's own daemon connection. It keeps no items: each caller reads what it needs
/// when the daemon says something changed (`feed-view-changed {revision, changed}`).
@MainActor
package final class FeedDaemonClient {
    /// One `feed.*` op on the local daemon: its raw result, or the daemon's refusal.
    package typealias Send = @MainActor (_ operation: String, _ params: [String: JSONValue], _ idempotencyKey: String?) async throws -> JSONValue

    /// What changed: the ids the commit touched, or nil when anything may have (a new connection).
    package struct Change: Sendable, Equatable {
        package var changed: [String]?
        package init(changed: [String]?) { self.changed = changed }
        package func touches(_ id: String) -> Bool { changed?.contains(id) ?? true }
    }

    /// The daemon's capability that serves the ops.
    package static let capability = "feed-client-v1"
    /// The daemon subscribe event of `feed.view.changed`.
    package static let changedEvent = "feed-view-changed"

    private let send: Send
    private var listeners: [UInt64: @MainActor (Change) -> Void] = [:]
    private var nextListener: UInt64 = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "feed.daemon")
    /// The GitHub setting last sent, and the posts no daemon took yet (by key): the daemon keeps
    /// both in memory only, so ``restore()`` sends them to each new serving connection.
    private var gitHub: [String: JSONValue]?
    private var pendingPosts: [String: [String: JSONValue]] = [:]

    package init(send: @escaping Send) {
        self.send = send
    }

    /// The client of the app's local daemon connection.
    package convenience init(connection: @escaping @MainActor () -> DaemonConnection?) {
        self.init { operation, params, key in
            guard let connection = connection() else { throw DaemonError.notConnected }
            return try await ResourceRelayClient(connection: connection).send(operation: operation, params: params, idempotencyKey: key)
        }
    }

    // MARK: Changes

    /// Calls `handler` with each change until the token is removed.
    @discardableResult
    package func observe(_ handler: @escaping @MainActor (Change) -> Void) -> UInt64 {
        nextListener += 1
        listeners[nextListener] = handler
        return nextListener
    }

    package func unobserve(_ token: UInt64) { listeners[token] = nil }

    /// Hands a daemon event to the listeners: `feed-view-changed`, or a new connection (`changed` nil).
    package func deliver(_ change: Change) {
        for listener in listeners.values { listener(change) }
    }

    /// A `feed-view-changed` payload as a change.
    package static func change(_ payload: JSONValue) -> Change {
        guard case .object(let members) = payload, case .array(let ids)? = members["changed"] else { return Change(changed: nil) }
        return Change(changed: ids.compactMap(\.stringValue))
    }

    /// A stream that yields once now and once per change that `touches` accepts, until the
    /// caller stops reading it (the consumer reads the daemon again on each element).
    package func changes(where touches: @escaping @MainActor (Change) -> Bool = { _ in true }) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = observe { change in if touches(change) { continuation.yield() } }
        continuation.yield()
        continuation.onTermination = { [weak self] _ in MainDelivery().run { [weak self] in self?.unobserve(token) } }
        return stream
    }

    // MARK: Reads

    /// `feed.view.read {layout, filter?, limit?}`.
    package func view(_ layout: FeedDaemonView.Layout, filter: [String: JSONValue]? = nil, limit: Int? = nil) async throws -> FeedDaemonView {
        var params: [String: JSONValue] = ["layout": .string(layout.rawValue)]
        if let filter { params["filter"] = .object(filter) }
        if let limit { params["limit"] = .number(Double(limit)) }
        params["tz_offset_min"] = .number(Double(TimeZone.current.secondsFromGMT() / 60))
        return try await Self.decode(FeedDaemonView.self, from: send("feed.view.read", params, nil))
    }

    /// `feed.item.get {ids, confirmed}`: with `confirmed`, the owner's own state (never a pending intent).
    /// More ids than one call takes (the daemon's 500) are read in calls of 500, none dropped.
    package func items(_ ids: [String], confirmed: Bool) async throws -> [FeedDaemonItem] {
        var out: [FeedDaemonItem] = []
        var start = ids.startIndex
        while start < ids.endIndex {
            let end = ids.index(start, offsetBy: Self.maxItemIDs, limitedBy: ids.endIndex) ?? ids.endIndex
            let params: [String: JSONValue] = ["ids": .array(ids[start..<end].map(JSONValue.string)), "confirmed": .bool(confirmed)]
            out += try await Self.decode(FeedDaemonItems.self, from: send("feed.item.get", params, nil)).items
            start = end
        }
        return out
    }

    /// The daemon's limit of ids per `feed.item.get`.
    static let maxItemIDs = 500

    /// `feed.items.list {state?, home?, confirmed: true}`: the owner's items in that state and home.
    package func list(state: String? = nil, home: String? = nil) async throws -> [FeedDaemonItem] {
        var params: [String: JSONValue] = ["confirmed": .bool(true)]
        if let state { params["state"] = .string(state) }
        if let home { params["home"] = .string(home) }
        return try await Self.decode(FeedDaemonItems.self, from: send("feed.items.list", params, nil)).items
    }

    /// `feed.github.find_work {}`: the person's review requests and assigned work.
    package func findWork() async throws -> FeedGitHubWork.Lists {
        try await Self.decode(FeedGitHubWork.Lists.self, from: send("feed.github.find_work", [:], nil))
    }

    // MARK: Mutations

    /// `feed.post {item}` into the daemon's integration owner (its dedupe keeps one per key).
    package func post(item: [String: JSONValue], key: String) async throws {
        _ = try await send("feed.post", ["item": .object(item)], key)
    }

    /// `feed.post` with nobody waiting: a post no daemon took stays pending for ``restore()``.
    package func keepPosting(item: [String: JSONValue], key: String) {
        pendingPosts[key] = item
        // task-owner: one daemon post; it clears the pending post once the daemon took it.
        Task { [weak self] in
            guard (try? await self?.post(item: item, key: key)) != nil else { return }
            self?.pendingPosts[key] = nil
        }
    }

    /// A new daemon connection serves the feed: it gets the GitHub setting and the pending posts.
    package func restore() {
        if let gitHub { fire("feed.github.configure", gitHub) }
        let pending = pendingPosts // a copy: keepPosting writes pendingPosts
        for (key, item) in pending { keepPosting(item: item, key: key) }
    }

    /// `feed.presence.set {active}`: the owner's push rule.
    package func setPresence(active: Bool) {
        fire("feed.presence.set", ["active": .bool(active)])
    }

    /// `feed.github.configure {enabled, interval_s}`.
    package func configureGitHub(enabled: Bool, intervalSeconds: Double) {
        let params: [String: JSONValue] = ["enabled": .bool(enabled), "interval_s": .number(intervalSeconds)]
        gitHub = params
        fire("feed.github.configure", params)
    }

    /// One mutation whose answer nobody waits on (a later call replaces its effect).
    private func fire(_ operation: String, _ params: [String: JSONValue]) {
        let send = send, logger = logger
        // task-owner: one daemon mutation with the control deadline; nothing waits on it.
        Task {
            do { _ = try await send(operation, params, "cmux-next-feed-" + UUID().uuidString.lowercased()) } catch {
                logger.info("\(operation, privacy: .public) not applied: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Waits

    /// Waits until the owner reports `id` closed or `deadline` passes; the owner-confirmed item it
    /// read last (nil when none answered).
    package func waitClosed(_ id: String, until deadline: ContinuousClock.Instant) async -> FeedDaemonItem? {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = observe { change in if change.touches(id) { continuation.yield() } }
        continuation.yield()
        // task-owner: FeedDaemonClient.waitClosed, one-shot request deadline (at most 120 s); ends this wait only.
        let timer = Task {
            // wakeup-allow: one-shot deadline of one feed wait, cancelled when the item closes.
            try? await ContinuousClock().sleep(until: deadline)
            continuation.finish()
        }
        defer {
            timer.cancel()
            unobserve(token)
        }
        var last: FeedDaemonItem?
        for await _ in stream {
            if let item = try? await items([id], confirmed: true).first {
                last = item
                if item.isClosed { break }
            }
            if ContinuousClock.now >= deadline { break }
        }
        return last
    }

    private static func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue) async throws -> T {
        try await FeedDaemonItems.decode(type, from: value)
    }
}

/// `feed.item.get` and `feed.items.list`'s reply.
package nonisolated struct FeedDaemonItems: Decodable, Sendable {
    package var items: [FeedDaemonItem]

    /// Decodes a daemon reply off the main actor (a view can hold many items).
    @concurrent package static func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue) async throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

/// `feed.view.read`'s reply, as far as the native glue reads it (feed-page.md 2 `FeedView`).
package nonisolated struct FeedDaemonView: Decodable, Sendable, Equatable {
    package enum Layout: String, Sendable { case list, inbox, needsYou = "needs_you" }

    package struct Connection: Decodable, Sendable, Equatable {
        package var state: String?
        package var reason: String?
    }

    package struct Counts: Decodable, Sendable, Equatable {
        package var openRequests: Int?
        package var unreadNotices: Int?
        package var badge: Int?
        package var unread: Int?
        enum CodingKeys: String, CodingKey {
            case badge, unread
            case openRequests = "open_requests", unreadNotices = "unread_notices"
        }
    }

    package struct Entry: Decodable, Sendable, Equatable {
        package var id: String
        package var item: FeedDaemonItem
    }

    package struct Group: Decodable, Sendable, Equatable {
        package var id: String
        package var entries: [Entry]
    }

    package var revision: Int?
    package var loaded: Bool?
    package var connection: Connection?
    package var counts: Counts?
    package var groups: [Group]?
    package var total: Int?

    /// Loaded and connected to its owner: an empty view then means nothing waits.
    package var isLive: Bool { loaded == true && connection?.state == "connected" }

    /// The whole truth for the glue: live; or disconnected once loaded (the mirror keeps the cloud
    /// items it had, the local owner's stay live) or signed out (no cloud items). `loaded` is the
    /// cloud part's hydration: the daemon sets it only on its owner's snapshot for this account, so
    /// a view still connecting, or after a first connection that failed, says nothing yet; nothing
    /// that replaces a whole set (the phone's Needs you, Home's notices) acts on it.
    package var isSettled: Bool {
        if isLive { return true }
        guard connection?.state == "disconnected" else { return false }
        return loaded == true || connection?.reason == "signed_out"
    }

    /// Every entry's head item, in the view's order.
    package var items: [FeedDaemonItem] { (groups ?? []).flatMap { $0.entries.map(\.item) } }

    /// The head items of the group `id`.
    package func items(in id: String) -> [FeedDaemonItem] { groups?.first { $0.id == id }?.entries.map(\.item) ?? [] }
}

/// One GitHub row of the Find Work palette (`feed.github.find_work`).
package nonisolated struct FeedGitHubWork: Decodable, Sendable, Equatable {
    package struct Lists: Decodable, Sendable, Equatable {
        package var reviews: [FeedGitHubWork]
        package var assigned: [FeedGitHubWork]

        package init(reviews: [FeedGitHubWork], assigned: [FeedGitHubWork]) {
            self.reviews = reviews
            self.assigned = assigned
        }
    }

    package var title: String
    package var url: String
    /// `owner/name`.
    package var repo: String
    package var number: Int
    /// The author's login.
    package var author: String?

    package init(title: String, url: String, repo: String, number: Int, author: String? = nil) {
        self.title = title
        self.url = url
        self.repo = repo
        self.number = number
        self.author = author
    }

    package var isPull: Bool { url.contains("/pull/") }
}
