import CmuxNextControl
import CmuxNextSettings
import CmuxNextHistory
import Foundation

/// `history.list {kind?, text?, limit?, range?}` for `cmux history list`
/// and `cmux history search` (plans/cmux-next/history.md 5.3). The main
/// actor only parses; the merge (SQLite reads, journal reads) runs as a
/// follow-up under the request deadline.
enum HistoryControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("history.list") { [weak services] call in
                let query = try query(from: call.params)
                guard let services else { return .value(.null) }
                return .followUp { await list(services, query) }
            },
        ]
    }

    static func query(from params: [String: JSONValue]) throws -> HistoryQuery {
        var query = HistoryQuery(limit: 100)
        if let text = params["text"]?.stringValue { query.text = text }
        if let limit = params["limit"]?.intValue { query.limit = max(1, min(limit, 5_000)) }
        if let kind = params["kind"]?.stringValue, kind != "all" {
            guard let parsed = HistoryEntry.Kind(rawValue: kind) else {
                throw ControlError.invalidParams("kind must be one of all, \(HistoryEntry.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            query.kinds = [parsed]
        }
        if let range = params["range"]?.stringValue {
            guard let parsed = HistoryRange(rawValue: range) else { throw ControlError.invalidParams("range must be hour, today, week, month or all") }
            query.range = parsed
        }
        return query
    }

    @MainActor
    static func list(_ services: AppServices, _ query: HistoryQuery) async -> JSONValue {
        let entries = await services.history.entries(query)
        return .object(["entries": .array(entries.map(json))])
    }

    static func json(_ entry: HistoryEntry) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(entry.id), "kind": .string(entry.kind.rawValue),
            "time": .string(ISO8601DateFormatter().string(from: entry.time)), "title": .string(entry.title),
            "available": .bool(entry.isAvailable),
        ]
        if let detail = entry.detail { object["detail"] = .string(detail) }
        if let machine = entry.machineName { object["machine"] = .string(machine) }
        switch entry.payload {
        case .page(let url, let profile):
            object["url"] = .string(url)
            object["browser_profile"] = .string(profile)
        case .location(let location, let isCurrent):
            object["tab"] = .string(location.key.tab)
            object["workspace"] = .string(location.workspace)
            object["current"] = .bool(isCurrent)
        case .closed(let item):
            object["closed_id"] = .string(item.id)
            if let url = item.url { object["url"] = .string(url) }
            if let cwd = item.cwd { object["cwd"] = .string(cwd) }
        case .agent(let session):
            object["provider"] = .string(session.provider)
            object["session_id"] = .string(session.sessionID)
            object["running"] = .bool(session.endedAt == nil)
            if let cwd = session.cwd { object["cwd"] = .string(cwd) }
            if let command = session.resumeCommand { object["resume_command"] = .string(command) }
        case .command(let command):
            if let text = command.command { object["command"] = .string(text) }
            if let cwd = command.cwd { object["cwd"] = .string(cwd) }
            if let code = command.exitCode { object["exit_code"] = .number(Double(code)) }
        }
        return .object(object)
    }
}
