import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The daemon history module (`history-v1`; plans/cmux-next/react-pages.md 2.2-2.3): the owner of
/// page visits, the hidden-history document and the merged read model. The app reports each visit
/// and title, and reads entries for the palette pages and `history.open`. Every mutation carries a
/// fresh idempotency key. The app keeps owning the location trail (client view state).
struct DaemonHistoryClient: Sendable {
    static let capability = "history-v1"

    let relay: ResourceRelayClient

    init(connection: DaemonConnection) {
        relay = ResourceRelayClient(connection: connection)
    }

    func list(kinds: Set<HistoryEntry.Kind>, text: String, range: HistoryRange, limit: Int?) async throws -> [DaemonHistoryEntry] {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)),
            "range": .string(range.rawValue),
            "local_day_start_ms": Self.decimal(Calendar.current.startOfDay(for: Date())),
        ]
        if !text.isEmpty { params["text"] = .string(text) }
        if let limit { params["limit"] = .number(Double(min(max(limit, 1), 5_000))) }
        let result = try await relay.send(operation: "history.entries.list", params: params, idempotencyKey: nil)
        return try Self.decode(DaemonHistoryList.self, from: result).entries
    }

    func remove(ids: [String]) async throws {
        _ = try await relay.send(operation: "history.entries.remove", params: ["ids": .array(ids.map(JSONValue.string))],
                                 idempotencyKey: Self.key())
    }

    func removeSite(host: String, profile: String?) async throws {
        var params: [String: JSONValue] = ["host": .string(host)]
        if let profile { params["profile"] = .string(profile) }
        _ = try await relay.send(operation: "history.site.remove", params: params, idempotencyKey: Self.key())
    }

    /// Clears `kinds` (empty: all) in `range`; a profile narrows the clear to its page visits.
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange, profile: String? = nil) async throws {
        var params: [String: JSONValue] = [
            "kinds": .array(kinds.map(\.rawValue).sorted().map(JSONValue.string)), "range": .string(range.rawValue),
            "local_day_start_ms": Self.decimal(Calendar.current.startOfDay(for: Date())),
        ]
        if let profile { params["profile"] = .string(profile) }
        _ = try await relay.send(operation: "history.clear", params: params, idempotencyKey: Self.key())
    }

    func recordVisit(profile: String, url: String, title: String?, tab: String?, at date: Date) async throws {
        var params: [String: JSONValue] = ["profile": .string(profile), "url": .string(url), "at_ms": Self.decimal(date)]
        if let tab { params["tab"] = .string(tab) }
        if let title, !title.isEmpty { params["title"] = .string(title) }
        _ = try await relay.send(operation: "history.visit.record", params: params, idempotencyKey: Self.key())
    }

    func updateTitle(profile: String, url: String, title: String) async throws {
        _ = try await relay.send(operation: "history.visit.title",
                                 params: ["profile": .string(profile), "url": .string(url), "title": .string(title)],
                                 idempotencyKey: Self.key())
    }

    func removeVisits(profile: String, url: String) async throws {
        _ = try await relay.send(operation: "history.visit.remove",
                                 params: ["profile": .string(profile), "urls": .array([.string(url)])],
                                 idempotencyKey: Self.key())
    }

    /// Hands the daemon the app's own visit log of `profile` from before the daemon owned page
    /// history. `key` names this file's import, so a retry after a lost reply imports nothing
    /// again. Returns how many visits came in.
    func importVisits(profile: String, path: String, key: String) async throws -> Int {
        let result = try await relay.send(operation: "history.visit.import",
                                          params: ["profile": .string(profile), "path": .string(path)], idempotencyKey: key)
        if case .object(let reply) = result, case .object(let value)? = reply["value"], case .number(let count)? = value["imported"] {
            return Int(count)
        }
        return 0
    }

    func summaries(profile: String, limit: Int = 5_000) async throws -> [DaemonVisitSummary] {
        let result = try await relay.send(operation: "history.visit.summaries",
                                          params: ["profile": .string(profile), "limit": .number(Double(limit))], idempotencyKey: nil)
        return try Self.decode([DaemonVisitSummary].self, from: result)
    }

    static func key() -> String { "cmux-next-history-" + UUID().uuidString.lowercased() }

    /// A time as the catalog's decimal string of Unix milliseconds.
    static func decimal(_ date: Date) -> JSONValue {
        .string(String(Int64((date.timeIntervalSince1970 * 1_000).rounded())))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
