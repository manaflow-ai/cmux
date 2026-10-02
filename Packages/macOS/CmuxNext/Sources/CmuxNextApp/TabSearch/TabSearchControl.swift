import CmuxNextControl
import CmuxNextPalette
import CmuxNextSettings
import Foundation

/// `tabs.search {query?, limit?, closed?}`: Search Tabs results for
/// `cmux tab search` and the MCP tool, ranked exactly like the palette page
/// (`TabSearchRanker`). Read-only and never changes focus. The main actor
/// only copies the entries (values); ranking runs in the follow-up.
///
/// Reply: `{"tabs": [{id, state: "open"|"closed", kind, title, url?, cwd?,
/// process?, workspace_id?, workspace?, window?, machine?, current,
/// available, last_used?, score}]}`, open tabs first. An open row's `id` is
/// the tab id (`cmux app show-tab --target <id>`, `cmux tab <id> close`); a closed row's is the
/// closed-items record id (`cmux history reopen <id>`).
enum TabSearchControl {
    nonisolated static let defaultLimit = 50
    nonisolated static let maximumLimit = 500

    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("tabs.search") { [weak services] call in
                let (query, limit, closed) = try parameters(call.params)
                guard let services else { return .value(.object(["tabs": .array([])])) }
                let entries = AppTabSearchSource(services: services).tabSearchEntries()
                let now = Date()
                return .followUp {
                    let matches = TabSearchRanker.search(entries, query: query, includeClosed: closed, limit: limit, now: now)
                    return .object(["tabs": .array(matches.map(json))])
                }
            },
        ]
    }

    nonisolated static func parameters(_ params: [String: JSONValue]) throws -> (query: String, limit: Int, closed: Bool) {
        var limit = defaultLimit
        if let value = params["limit"] {
            guard let parsed = value.intValue, parsed > 0 else { throw ControlError.invalidParams("limit must be a positive integer") }
            limit = min(parsed, maximumLimit)
        }
        if let value = params["query"], value.stringValue == nil, value != .null {
            throw ControlError.invalidParams("query must be a string")
        }
        if let value = params["closed"], value.boolValue == nil { throw ControlError.invalidParams("closed must be a boolean") }
        return (params["query"]?.stringValue ?? "", limit, params["closed"]?.boolValue ?? true)
    }

    nonisolated static func json(_ match: TabSearchMatch) -> JSONValue {
        let entry = match.row.entry
        var object: [String: JSONValue] = [
            "id": .string(entry.id), "state": .string(entry.isClosed ? "closed" : "open"), "kind": .string(entry.kind == .remoteTerminal ? "remote_terminal" : entry.kind.rawValue),
            "title": .string(match.row.title), "current": .bool(entry.isCurrent), "available": .bool(entry.isAvailable),
            "score": .number(Double(match.score)),
        ]
        let optional: [(String, String?)] = [
            ("url", entry.url), ("cwd", entry.cwd), ("process", entry.process), ("workspace_id", entry.workspaceID),
            ("workspace", entry.workspaceTitle), ("window", entry.windowTitle), ("machine", entry.machine),
            ("last_used", entry.lastUsed.map { ISO8601DateFormatter().string(from: $0) }),
        ]
        for (key, value) in optional { if let value { object[key] = .string(value) } }
        return .object(object)
    }
}
