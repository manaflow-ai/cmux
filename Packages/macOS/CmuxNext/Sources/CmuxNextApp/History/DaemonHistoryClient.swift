import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextIPC
import Foundation

/// The daemon history module (`history-v1`; plans/cmux-next/react-pages.md 2.2-2.3): the owner of
/// page visits, the hidden-history document and the merged read model. The app reports each visit
/// and title, and reads entries for the palette pages and `history.open`. Every mutation carries a
/// fresh idempotency key. The daemon also owns the location trail (DaemonTrailLocation.swift); the app
/// keeps only its Back/Forward cursor.
///
/// Each call sends a generated `cmux.protocol/2` request (CmuxNextIPC's `V2<Operation>Request`,
/// p05-ipc Q11) through ``ResourceOperationClient``, as Mojo's generated proxies serialize a typed
/// params struct (mojo/public/tools/bindings/generators/cpp_templates/interface_definition.tmpl).
/// The request builders below are what DaemonHistoryWireGoldenTests check. A reply decodes once,
/// on the connection's actor, never on the main actor.
struct DaemonHistoryClient: Sendable {
    static let capability = "history-v1"

    let operations: ResourceOperationClient
    /// The connection itself, for the trail document (``trail()``).
    let connection: DaemonConnection

    init(connection: DaemonConnection) {
        self.connection = connection
        operations = ResourceOperationClient(connection: connection)
    }

    func list(kinds: Set<HistoryEntry.Kind>, text: String, range: HistoryRange, limit: Int?) async throws -> [DaemonHistoryEntry] {
        let request = Self.listRequest(kinds: kinds, text: text, range: range, limit: limit,
                                       dayStart: Calendar.current.startOfDay(for: Date()))
        return try await operations.read(request, as: DaemonHistoryList.self).entries
    }

    func remove(ids: [String]) async throws {
        try await mutate(V2HistoryEntriesRemoveRequest(ids: ids))
    }

    func removeSite(host: String, profile: String?) async throws {
        try await mutate(V2HistorySiteRemoveRequest(host: host, profile: profile))
    }

    /// Clears `kinds` (empty: all) in `range`; a profile narrows the clear to its page visits.
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange, profile: String? = nil) async throws {
        try await mutate(Self.clearRequest(kinds: kinds, range: range, profile: profile,
                                           dayStart: Calendar.current.startOfDay(for: Date())))
    }

    func recordVisit(profile: String, url: String, title: String?, tab: String?, at date: Date) async throws {
        try await mutate(Self.visitRequest(profile: profile, url: url, title: title, tab: tab, at: date))
    }

    func updateTitle(profile: String, url: String, title: String) async throws {
        try await mutate(V2HistoryVisitTitleRequest(profile: profile, title: title, url: url))
    }

    func removeVisits(profile: String, url: String) async throws {
        try await mutate(V2HistoryVisitRemoveRequest(profile: profile, urls: [url]))
    }

    /// Hands the daemon the app's own visit log of `profile` from before the daemon owned page
    /// history. `key` names this file's import, so a retry after a lost reply imports nothing
    /// again. Returns how many visits came in.
    func importVisits(profile: String, path: String, key: String) async throws -> Int {
        let result = try await mutate(V2HistoryVisitImportRequest(path: path, profile: profile), key: key,
                                      value: V2HistoryVisitImportResult.self)
        return Int(result.imported)
    }

    func summaries(profile: String, limit: Int = 5_000) async throws -> [DaemonVisitSummary] {
        try await operations.read(Self.summariesRequest(profile: profile, limit: limit), as: [DaemonVisitSummary].self)
    }

    /// Sends mutation `request` under `key` (a fresh one by default) and answers the `value` of
    /// its `MutationResult`.
    @discardableResult
    func mutate<Request: ResourceMutationRequest, Value: Decodable & Sendable>(
        _ request: Request, key: String = DaemonHistoryClient.key(), value: Value.Type = JSONValue.self
    ) async throws -> Value {
        try await operations.mutate(request, idempotencyKey: key, as: ResourceMutationResult<Value>.self).value
    }

    static func key() -> String { "cmux-next-history-" + UUID().uuidString.lowercased() }

    /// A time as the catalog's decimal string of Unix milliseconds.
    static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    /// The kinds as the catalog's `HistoryKind`s, sorted, so one query always writes one line.
    static func wireKinds(_ kinds: Set<HistoryEntry.Kind>) -> [V2HistoryKind] {
        kinds.map(\.rawValue).sorted().map { V2HistoryKind(rawValue: $0) }
    }

    /// `history.entries.list`: `text` only when there is one, `limit` clamped to the catalog's 1...5,000.
    static func listRequest(kinds: Set<HistoryEntry.Kind>, text: String, range: HistoryRange, limit: Int?,
                            dayStart: Date) -> V2HistoryEntriesListRequest {
        V2HistoryEntriesListRequest(kinds: wireKinds(kinds), limit: limit.map { UInt32(min(max($0, 1), 5_000)) },
                                    localDayStartMs: milliseconds(dayStart),
                                    range: V2HistoryRange(rawValue: range.rawValue), text: text.isEmpty ? nil : text)
    }

    /// `history.clear`: every kind when `kinds` is empty; a profile narrows it to that profile's visits.
    static func clearRequest(kinds: Set<HistoryEntry.Kind>, range: HistoryRange, profile: String?,
                             dayStart: Date) -> V2HistoryClearRequest {
        V2HistoryClearRequest(kinds: wireKinds(kinds), localDayStartMs: milliseconds(dayStart), profile: profile,
                              range: V2HistoryRange(rawValue: range.rawValue))
    }

    /// `history.visit.record`: an empty title is left out, as is an unknown tab.
    static func visitRequest(profile: String, url: String, title: String?, tab: String?,
                             at date: Date) -> V2HistoryVisitRecordRequest {
        V2HistoryVisitRecordRequest(atMs: milliseconds(date), profile: profile, tab: tab,
                                    title: title?.isEmpty == false ? title : nil, url: url)
    }

    /// `history.visit.summaries` of `profile`, at most `limit` URLs.
    static func summariesRequest(profile: String, limit: Int) -> V2HistoryVisitSummariesRequest {
        V2HistoryVisitSummariesRequest(limit: UInt32(clamping: limit), profile: profile)
    }

    /// Decodes a stored projection on the global executor: a history document can hold thousands
    /// of rows, so the decode never runs on the main actor.
    @concurrent static func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue) async throws -> T {
        try JSONDecoder().blockingDecode(T.self, from: JSONEncoder().encode(value))
    }
}
