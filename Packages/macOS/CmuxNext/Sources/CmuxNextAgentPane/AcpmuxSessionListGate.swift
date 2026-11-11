import Foundation

/// The `_acpmux/sessions` filters a capability serves, and the one check every request that
/// sends one goes through. An older acpmux ignores a param it does not know and answers the
/// whole list, never an error: a filter sent unchecked reads every peer's sessions (31 MB on a
/// Mac that mirrors ~10,000) and the caller takes them for the narrowed list. A filter goes
/// only to an acpmux whose `initialize` lists its capability; any other gets the paged whole
/// list, narrowed here. `AcpmuxSessionListGateTests` refuses a gated field built anywhere else.
public nonisolated struct AcpmuxSessionListGate: Sendable, Equatable {
    /// `localOnly`, `excludeStatus` and `orderBy` (acpmux `capabilities.rs`).
    public static let filtersCapability = "session-list-filters-v1"
    /// `pendingOnly` (acpmux `capabilities.rs`).
    public static let pendingCapability = "session-list-pending-v1"
    /// Each gated field and the capability that serves it.
    static let gatedFields: [String: String] = [
        "localOnly": filtersCapability, "excludeStatus": filtersCapability, "orderBy": filtersCapability,
        "pendingOnly": pendingCapability,
    ]
    /// The quit census's read (`AcpmuxQuit`): this daemon's own sessions that are not closed, in a
    /// stable id order; sent only with ``requiredCapability(fields:)``.
    public static let localLiveCensus: [String: any Sendable] = [
        "localOnly": true, "excludeStatus": ["closed"], "orderBy": "sessionId",
    ]
    /// Rows a page of the whole list asks for.
    static let pageSize = 64

    /// The surfaces this acpmux serves.
    public let capabilities: Set<String>

    public init(capabilities: Set<String>) {
        self.capabilities = capabilities
    }

    /// The surfaces an `initialize` result lists (`_meta.acpmux.capabilities`); none without one.
    public init(initialize result: [String: Any]?) {
        let meta = (result?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        self.init(capabilities: Set(meta?["capabilities"] as? [String] ?? []))
    }

    /// The capability a request with `fields` needs from acpmux; nil when any acpmux serves them.
    public static func requiredCapability(fields: some Sequence<String>) -> String? {
        Set(fields.compactMap { gatedFields[$0] }).sorted().first
    }

    /// The sessions with a pending permission or question: `{pendingOnly: true}` from an acpmux
    /// that serves it (never paged, never paced), else every session page by page, kept to those
    /// with one. Nil when a read failed.
    @MainActor
    public func pendingSessions(call: @MainActor (String, [String: Any]) async -> [String: Any]?) async -> [[String: Any]]? {
        if capabilities.contains(Self.pendingCapability) {
            return (await call("_acpmux/sessions", ["pendingOnly": true]))?["sessions"] as? [[String: Any]]
        }
        return await Self.allSessions(call: call)?
            .filter { ($0["pendingPermissions"] as? NSNumber)?.intValue ?? 0 > 0 }
    }

    /// The ids of ``pendingSessions(call:)``; none when the read failed.
    @MainActor
    public func pendingSessionIDs(call: @MainActor (String, [String: Any]) async -> [String: Any]?) async -> [String] {
        (await pendingSessions(call: call) ?? []).compactMap { $0["sessionId"] as? String }
    }

    /// Every session, page by page; nil on a failed page or a repeated cursor.
    @MainActor
    static func allSessions(call: @MainActor (String, [String: Any]) async -> [String: Any]?) async -> [[String: Any]]? {
        var sessions: [[String: Any]] = []
        var cursor: String?
        var seen: Set<String> = []
        var seenSessions: Set<String> = []
        while true { // wakeup-allow: each pass awaits a daemon page; a terminal page, malformed reply, or repeated cursor ends it
            var params: [String: Any] = ["limit": pageSize]
            if let cursor { params["cursor"] = cursor }
            guard let page = await call("_acpmux/sessions", params) else { return nil }
            guard let pageRows = page["sessions"] as? [[String: Any]] else { return nil }
            for row in pageRows {
                guard let id = row["sessionId"] as? String, !id.isEmpty else { continue }
                let key = "\(row["peer"] as? String ?? "")/\(id)"
                if seenSessions.insert(key).inserted { sessions.append(row) }
            }
            guard let next = (page["nextCursor"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { break }
            guard seen.insert(next).inserted else { return nil }
            cursor = next
        }
        return sessions
    }
}
