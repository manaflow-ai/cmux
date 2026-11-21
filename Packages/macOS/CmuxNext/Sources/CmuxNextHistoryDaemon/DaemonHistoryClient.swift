public import CmuxNextDaemon
public import CmuxNextHistory
public import Foundation
public import CmuxNextWakeups

/// The daemon history module (`history-v1`; plans/cmux-next/react-pages.md 2.2-2.3): the owner of
/// page visits, the hidden-history document and the merged read model. The app reports each visit
/// and title, and reads entries for the palette pages and `history.open`. Every mutation carries a
/// fresh idempotency key. The daemon also owns the location trail (DaemonTrailLocation.swift); the app
/// keeps only its Back/Forward cursor.
public struct DaemonHistoryClient: Sendable {
    public static let capability = "history-v1"

    public let relay: ResourceRelayClient
    /// The connection itself, for the trail document (``trail()``).
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
        relay = ResourceRelayClient(connection: connection)
    }

    public func list(kinds: Set<HistoryEntry.Kind>, text: String, range: HistoryRange, limit: Int?) async throws -> DaemonHistoryList {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)),
            "range": .string(range.rawValue),
            "local_day_start_ms": Self.decimal(Calendar.current.startOfDay(for: Date())),
        ]
        if !text.isEmpty { params["text"] = .string(text) }
        if let limit { params["limit"] = .number(Double(min(max(limit, 1), 5_000))) }
        let result = try await relay.send(operation: "history.entries.list", params: params, idempotencyKey: nil)
        return try await Self.decode(DaemonHistoryList.self, from: result)
    }

    /// Runs `read` up to `attempts` times, spaced by `backoff` (a busy daemon times out once, then
    /// answers). nil when no attempt answered, never an empty list in its place.
    public static func retrying<T>(attempts: Int = 3, backoff: Backoff = Backoff(initial: .milliseconds(150), maximum: .seconds(1)),
                                   _ read: () async throws -> T) async -> T? {
        var backoff = backoff
        for attempt in 1...max(1, attempts) {
            if let value = try? await read() { return value }
            guard attempt < attempts else { break }
            // concurrency-allow: Backoff.wait is an async clock sleep (the task suspends, no thread blocks), at most twice per read
            do { try await backoff.wait(owner: "history.read") } catch { break }
        }
        return nil
    }

    /// Waits before the next read of a list that is not complete (`pending_kinds`), after `reads` reads:
    /// 1 s, 2 s, 4 s, then 8 s each time. `history-changed` does not replace it: that event comes only when a
    /// fold changes an entry of the kind. Throws `CancellationError` when the reader goes away.
    public static func waitForPending(afterReads reads: Int, clock: any Clock<Duration> = ContinuousClock()) async throws {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(8), multiplier: 2, jitter: 0)
        for _ in 1..<max(1, reads) { _ = backoff.next() }
        // concurrency-allow: Backoff.wait is an async clock sleep (the task suspends, no thread blocks), one per read of a list that is not complete
        try await backoff.wait(owner: "history.pending", clock: clock)
    }

    public func remove(ids: [String], key: String = DaemonHistoryClient.key()) async throws {
        _ = try await relay.send(operation: "history.entries.remove", params: ["ids": .array(ids.map(JSONValue.string))],
                                 idempotencyKey: key)
    }

    public func removeSite(host: String, profile: String?, key: String = DaemonHistoryClient.key()) async throws {
        var params: [String: JSONValue] = ["host": .string(host)]
        if let profile { params["profile"] = .string(profile) }
        _ = try await relay.send(operation: "history.site.remove", params: params, idempotencyKey: key)
    }

    /// The daemon takes `until_ms` on `history.clear` (the end of a clear that waited in the queue).
    public static let clearUntilCapability = DaemonCapability.historyClearUntil.rawValue

    /// Clears `kinds` (empty: all) from `since` (nil: all time) until `until`; a profile narrows the clear to
    /// its page visits. Both are taken when the person clicked, so a clear the queue delivers later still
    /// covers that span, never one counted from the delivery (activity after the click stays). A daemon
    /// without ``clearUntilCapability`` clears until its own now, so there the clear goes only when `unbounded` (sent at the
    /// click, ``HistoryWriteQueue/enqueueClear(live:_:_:done:)``), else it is dropped.
    public func clear(kinds: Set<HistoryEntry.Kind>, since: Date?, until: Date, profile: String? = nil, unbounded: Bool,
                      key: String = DaemonHistoryClient.key()) async throws {
        let bounded = await connection.identity?.supports(Self.clearUntilCapability) == true
        try await Self.sendClear(kinds: kinds, since: since, until: until, profile: profile, bounded: bounded, unbounded: unbounded) {
            _ = try await relay.send(operation: "history.clear", params: $0, idempotencyKey: key)
        }
    }

    /// Sends `history.clear`'s params with `send`: with `until_ms` when the daemon takes it (`bounded`), else only when
    /// `unbounded` (sent at the click). The one place every history clear passes.
    public static func sendClear(kinds: Set<HistoryEntry.Kind>, since: Date?, until: Date, profile: String?, bounded: Bool,
                                 unbounded: Bool, _ send: ([String: JSONValue]) async throws -> Void) async throws {
        guard DaemonHistoryClient.mayClear(bounded: bounded, unbounded: unbounded, "history.clear") else { return }
        try await send(clearParams(kinds: kinds, since: since, until: bounded ? until : nil, profile: profile))
    }

    /// `history.clear`'s params for an absolute start: range `today` starts at the given
    /// `local_day_start_ms`, the daemon's one absolute range start; nil is range `all`. `until` is `until_ms`.
    public static func clearParams(kinds: Set<HistoryEntry.Kind>, since: Date?, until: Date? = nil, profile: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)),
            "range": .string((since == nil ? HistoryRange.all : .today).rawValue),
        ]
        if let since { params["local_day_start_ms"] = decimal(max(since, Date(timeIntervalSince1970: 0))) }
        if let until { params["until_ms"] = decimal(max(until, Date(timeIntervalSince1970: 0))) }
        if let profile { params["profile"] = .string(profile) }
        return params
    }

    public func recordVisit(profile: String, url: String, title: String?, tab: String?, at date: Date, key: String = DaemonHistoryClient.key()) async throws {
        var params: [String: JSONValue] = ["profile": .string(profile), "url": .string(url), "at_ms": Self.decimal(date)]
        if let tab { params["tab"] = .string(tab) }
        if let title, !title.isEmpty { params["title"] = .string(title) }
        _ = try await relay.send(operation: "history.visit.record", params: params, idempotencyKey: key)
    }

    public func updateTitle(profile: String, url: String, title: String, key: String = DaemonHistoryClient.key()) async throws {
        _ = try await relay.send(operation: "history.visit.title",
                                 params: ["profile": .string(profile), "url": .string(url), "title": .string(title)],
                                 idempotencyKey: key)
    }

    public func removeVisits(profile: String, url: String, key: String = DaemonHistoryClient.key()) async throws {
        _ = try await relay.send(operation: "history.visit.remove",
                                 params: ["profile": .string(profile), "urls": .array([.string(url)])],
                                 idempotencyKey: key)
    }

    /// Hands the daemon the app's own visit log of `profile` from before the daemon owned page
    /// history. `key` names this file's import, so a retry after a lost reply imports nothing
    /// again. Returns how many visits came in.
    public func importVisits(profile: String, path: String, key: String) async throws -> Int {
        let result = try await relay.send(operation: "history.visit.import",
                                          params: ["profile": .string(profile), "path": .string(path)], idempotencyKey: key)
        if case .object(let reply) = result, case .object(let value)? = reply["value"], case .number(let count)? = value["imported"] {
            return Int(count)
        }
        return 0
    }

    public func summaries(profile: String, limit: Int = 5_000) async throws -> [DaemonVisitSummary] {
        let result = try await relay.send(operation: "history.visit.summaries",
                                          params: ["profile": .string(profile), "limit": .number(Double(limit))], idempotencyKey: nil)
        return try await Self.decode([DaemonVisitSummary].self, from: result)
    }

    public static func key() -> String { "cmux-next-history-" + UUID().uuidString.lowercased() }

    /// A time as the catalog's decimal string of Unix milliseconds.
    public static func decimal(_ date: Date) -> JSONValue {
        .string(String(Int64((date.timeIntervalSince1970 * 1_000).rounded())))
    }

    /// Decodes a relay reply on the global executor: a history page or a profile's visit summaries
    /// can hold thousands of rows, so the decode never runs on the main actor.
    @concurrent public static func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue) async throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
