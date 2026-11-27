import CmuxNextControl
import CmuxNextPalette
import CmuxNextSettings
import Foundation

/// `tabs.search {query?, limit?, closed?}`: Search Tabs results for
/// `cmux tab search` and the MCP tool, ranked exactly like the palette page
/// (`TabSearchRanker`). Read-only, never changes focus, and answered off
/// the main actor from the published control snapshot (architecture.md 5a):
/// topology plus `ControlTabSearchFacts`.
///
/// Reply: `{"tabs": [{id, state: "open"|"closed", kind, title, url?, cwd?,
/// process?, workspace_id?, workspace?, window?, machine?, current,
/// available, last_used?, score}]}`, open tabs first. An open row's `id` is
/// the tab id (`cmux app show-tab --target <id>`, `cmux tab <id> close`); a closed row's is the
/// closed-items record id (`cmux history reopen <id>`).
nonisolated enum TabSearchControl {
    static let defaultLimit = 50
    static let maximumLimit = 500

    static func methods() -> [ControlMethod] {
        let ranker = TabSearchRanker()
        return [
            ControlMethod.snapshot("tabs.search") { call in
                let (query, limit, closed) = try parameters(call.params)
                let entries = TabSearchEntries.entries(call.snapshot.topology, call.snapshot.tabSearch)
                let matches = ranker.search(entries, query: query, includeClosed: closed, limit: limit, now: Date())
                return .object(["tabs": .array(matches.map(json))])
            },
        ]
    }

    static func parameters(_ params: [String: JSONValue]) throws -> (query: String, limit: Int, closed: Bool) {
        var limit = defaultLimit
        if let value = params["limit"], value != .null {
            guard let parsed = value.intValue, parsed > 0 else { throw ControlError.invalidParams("limit must be a positive integer") }
            limit = min(parsed, maximumLimit)
        }
        if let value = params["query"], value.stringValue == nil, value != .null {
            throw ControlError.invalidParams("query must be a string")
        }
        if let value = params["closed"], value != .null, value.boolValue == nil {
            throw ControlError.invalidParams("closed must be a boolean")
        }
        return (params["query"]?.stringValue ?? "", limit, params["closed"]?.boolValue ?? true)
    }

    static func json(_ match: TabSearchMatch) -> JSONValue {
        let entry = match.row.entry
        var object: [String: JSONValue] = [
            "id": .string(entry.id), "state": .string(entry.isClosed ? "closed" : "open"),
            "kind": .string(entry.kind == .remoteTerminal ? "remote_terminal" : entry.kind.rawValue),
            "title": .string(match.row.title), "current": .bool(entry.isCurrent), "available": .bool(entry.isAvailable),
            "score": .number(Double(match.score)),
        ]
        let formatter = ISO8601DateFormatter()
        let optional: [(String, String?)] = [
            ("url", entry.url), ("cwd", entry.cwd), ("process", entry.process), ("workspace_id", entry.workspaceID),
            ("workspace", entry.workspaceTitle), ("window", entry.windowTitle), ("machine", entry.machine),
            ("last_used", entry.lastUsed.flatMap { $0 == .distantPast ? nil : formatter.string(from: $0) }),
        ]
        for (key, value) in optional { if let value { object[key] = .string(value) } }
        return .object(object)
    }
}
