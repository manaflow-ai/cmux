import Foundation

/// One live Computer Use session on this Mac, as the File menu's Computer Use
/// actions need it: what it drives and which terminal started it. Read from
/// the CUA host's `activity_sessions_list` (plans/cmux-next/computer-use.md
/// section 6a, `SessionRecord`).
nonisolated struct ComputerUseLiveSession: Equatable, Sendable {
    /// The app window the session last acted on.
    nonisolated struct Target: Equatable, Sendable {
        var pid: Int32?
        var bundleID: String?
        var appName: String?
    }

    var id: String
    var lastActionAt: Date
    /// The newest target (the host lists targets oldest first); nil before the first act.
    var target: Target?
    /// The session host terminal the agent runs in (`agent.terminal_id`), when attributed.
    var terminalID: String?
    var workspaceID: String?

    /// The live (not ended) sessions of an `activity_sessions_list` result, newest action first.
    static func live(from result: [String: Any]) -> [ComputerUseLiveSession] {
        let rows = result["sessions"] as? [[String: Any]] ?? []
        return rows.compactMap(session).sorted { $0.lastActionAt > $1.lastActionAt }
    }

    private static func session(_ json: [String: Any]) -> ComputerUseLiveSession? {
        guard let id = json["id"] as? String, !id.isEmpty,
              (json["status"] as? [String: Any])?["state"] as? String != "ended" else { return nil }
        let agent = json["agent"] as? [String: Any] ?? [:]
        let target = (json["targets"] as? [[String: Any]])?.last.map { row in
            Target(pid: (row["pid"] as? NSNumber)?.int32Value, bundleID: nonEmpty(row["app_bundle_id"]),
                   appName: nonEmpty(row["app_name"]))
        }
        let millis = (json["last_action_at_ms"] as? NSNumber)?.doubleValue ?? (json["started_at_ms"] as? NSNumber)?.doubleValue ?? 0
        return ComputerUseLiveSession(id: id, lastActionAt: Date(timeIntervalSince1970: millis / 1000), target: target,
                                      terminalID: nonEmpty(agent["terminal_id"]), workspaceID: nonEmpty(agent["workspace_id"]))
    }
}

nonisolated private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
}
