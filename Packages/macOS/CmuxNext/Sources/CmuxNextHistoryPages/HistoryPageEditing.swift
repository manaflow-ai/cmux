public import CmuxNextHistory
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The app's History owner as the History page reaches it: the calls the native page made
/// (HistoryService). `read` is the merged read model (the local daemon's entries, every machine's
/// command rows, locations greyed while unreachable). Each page's provider keeps the entries its
/// list showed (``HistoryCookieBackupsPageProvider/shown``), and `entry(id:)` finds one any open
/// page shows (an older search hit) for a remove or an open, as the native page passed its loaded entry.
/// A remove or clear also drops the pages from every profile's omnibar suggestions.
@MainActor
public protocol HistoryPageEditing: AnyObject {
    func read(_ query: HistoryQuery) async -> HistoryRead
    func entry(id: String) async -> HistoryEntry?
    func remove(_ entry: HistoryEntry)
    func removePages(host: String)
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange)
}

extension HistoryPageEditing {
    /// The read of `cmux.history.entries.list {kinds?, text?, range?, limit?}`. Closed when no owner answered.
    func list(_ params: CmuxNextSettings.JSONValue) async throws -> HistoryRead {
        var query = HistoryQuery(text: params["text"]?.stringValue ?? "", kinds: try Self.kinds(params),
                                 limit: max(1, min(params["limit"]?.intValue ?? 1_000, 5_000)))
        if let range = params["range"]?.stringValue {
            guard let parsed = HistoryRange(rawValue: range) else { throw PageError.invalidParams("range must be hour, today, week, month or all") }
            query.range = parsed
        }
        let read = await read(query)
        // No owner answered: the page shows its disconnected state, as for a closed relay.
        if read.unavailable, read.entries.isEmpty { throw PageError.closed }
        return read
    }

    /// The page op's params, read the way the daemon reads them; anything else is refused.
    func apply(_ op: String, _ params: CmuxNextSettings.JSONValue) async throws {
        switch op {
        case "cmux.history.entries.remove":
            let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !ids.isEmpty, ids.count == params["ids"]?.arrayValue?.count else { throw PageError.invalidParams("ids must be entry ids") }
            for id in ids {
                if let entry = await entry(id: id) { remove(entry) }
            }
        case "cmux.history.site.remove":
            guard let host = params["host"]?.stringValue, !host.isEmpty else { throw PageError.invalidParams("host is required") }
            removePages(host: host)
        default:
            guard let range = params["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) else { throw PageError.invalidParams("range is required") }
            clear(kinds: try Self.kinds(params), range: range)
        }
    }

    private static func kinds(_ params: CmuxNextSettings.JSONValue) throws -> Set<HistoryEntry.Kind> {
        let names = params["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let kinds = Set(names.compactMap(HistoryEntry.Kind.init(rawValue:)))
        guard kinds.count == names.count else { throw PageError.invalidParams("kinds names an unknown kind") }
        return kinds
    }
}

extension HistoryEntry {
    /// The page's row: the daemon's `history.entries.list` shape (snake_case, `at_ms`).
    var pageJSON: CmuxNextSettings.JSONValue {
        var row: [String: CmuxNextSettings.JSONValue] = [
            "id": .string(id), "kind": .string(kind.rawValue), "at_ms": .number((time.timeIntervalSince1970 * 1_000).rounded()),
            "title": .string(title), "available": .bool(isAvailable),
        ]
        func put(_ key: String, _ value: String?) { if let value { row[key] = .string(value) } }
        put("detail", detail)
        put("machine", machineName)
        switch payload {
        case .page(let url, let profile):
            put("url", url)
            put("profile", profile)
        case .location(let location, let isCurrent):
            row["current"] = .bool(isCurrent)
            put("workspace", location.workspaceTitle)
            put("url", location.url)
            put("cwd", location.cwd)
        case .closed(let item):
            let kinds: [ClosedItem.Kind: String] = [.terminalTab: "terminal_tab", .browserTab: "browser_tab",
                                                    .conversationTab: "conversation_tab", .screen: "screen", .workspace: "workspace"]
            put("closed_kind", kinds[item.kind])
            put("workspace", item.workspace)
            put("url", item.url)
            put("cwd", item.cwd)
            put("session_id", item.agentSession?.sessionID)
            put("provider", item.agentSession?.harness)
        case .command(let command):
            put("command", command.command)
            put("cwd", command.cwd)
            if let code = command.exitCode { row["exit_code"] = .number(Double(code)) }
        case .agent(let session):
            row["running"] = .bool(session.endedAt == nil)
            put("session_id", session.sessionID)
            put("provider", session.provider)
            put("cwd", session.cwd)
            put("workspace", session.workspace)
        }
        return .object(row)
    }
}
