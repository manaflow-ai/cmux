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

    public func list(kinds: Set<HistoryEntry.Kind>, text: String, range: HistoryRange, limit: Int?) async throws -> [DaemonHistoryEntry] {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)),
            "range": .string(range.rawValue),
            "local_day_start_ms": Self.decimal(Calendar.current.startOfDay(for: Date())),
        ]
        if !text.isEmpty { params["text"] = .string(text) }
        if let limit { params["limit"] = .number(Double(min(max(limit, 1), 5_000))) }
        let result = try await relay.send(operation: "history.entries.list", params: params, idempotencyKey: nil)
        return try await Self.decode(DaemonHistoryList.self, from: result).entries
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

    public func remove(ids: [String]) async throws {
        _ = try await relay.send(operation: "history.entries.remove", params: ["ids": .array(ids.map(JSONValue.string))],
                                 idempotencyKey: Self.key())
    }

    public func removeSite(host: String, profile: String?) async throws {
        var params: [String: JSONValue] = ["host": .string(host)]
        if let profile { params["profile"] = .string(profile) }
        _ = try await relay.send(operation: "history.site.remove", params: params, idempotencyKey: Self.key())
    }

    /// Clears `kinds` (empty: all) in `range`; a profile narrows the clear to its page visits.
    public func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange, profile: String? = nil) async throws {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)), "range": .string(range.rawValue),
            "local_day_start_ms": Self.decimal(Calendar.current.startOfDay(for: Date())),
        ]
        if let profile { params["profile"] = .string(profile) }
        _ = try await relay.send(operation: "history.clear", params: params, idempotencyKey: Self.key())
    }

    public func recordVisit(profile: String, url: String, title: String?, tab: String?, at date: Date) async throws {
        var params: [String: JSONValue] = ["profile": .string(profile), "url": .string(url), "at_ms": Self.decimal(date)]
        if let tab { params["tab"] = .string(tab) }
        if let title, !title.isEmpty { params["title"] = .string(title) }
        _ = try await relay.send(operation: "history.visit.record", params: params, idempotencyKey: Self.key())
    }

    public func updateTitle(profile: String, url: String, title: String) async throws {
        _ = try await relay.send(operation: "history.visit.title",
                                 params: ["profile": .string(profile), "url": .string(url), "title": .string(title)],
                                 idempotencyKey: Self.key())
    }

    public func removeVisits(profile: String, url: String) async throws {
        _ = try await relay.send(operation: "history.visit.remove",
                                 params: ["profile": .string(profile), "urls": .array([.string(url)])],
                                 idempotencyKey: Self.key())
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
