public import Foundation

/// One live Computer Use session on this Mac, as the File menu's Computer Use
/// actions need it: what it drives and which terminal started it. Read from
/// the CUA host's `activity_sessions_list` (plans/cmux-next/computer-use.md
/// section 6a, `SessionRecord`).
public nonisolated struct ComputerUseLiveSession: Equatable, Sendable {
    /// The app window the session last acted on.
    public nonisolated struct Target: Equatable, Sendable {
        /// The app's process, when known.
        public var pid: Int32?
        /// The app's bundle id, when known.
        public var bundleID: String?
        /// The app's name, when known.
        public var appName: String?

        /// - Parameters:
        ///   - pid: The app's process.
        ///   - bundleID: The app's bundle id.
        ///   - appName: The app's name.
        public init(pid: Int32? = nil, bundleID: String? = nil, appName: String? = nil) {
            self.pid = pid
            self.bundleID = bundleID
            self.appName = appName
        }
    }

    /// The session's id.
    public var id: String
    /// When the session last acted.
    public var lastActionAt: Date
    /// The newest target (the host lists targets oldest first); nil before the first act.
    public var target: Target?
    /// The session host terminal the agent runs in (`agent.terminal_id`), when attributed.
    public var terminalID: String?
    /// The workspace the agent runs in (`agent.workspace_id`), when attributed.
    public var workspaceID: String?

    /// - Parameters:
    ///   - id: The session's id.
    ///   - lastActionAt: When it last acted.
    ///   - target: What it drives.
    ///   - terminalID: The terminal it started in.
    ///   - workspaceID: The workspace it started in.
    public init(id: String, lastActionAt: Date, target: Target? = nil, terminalID: String? = nil, workspaceID: String? = nil) {
        self.id = id
        self.lastActionAt = lastActionAt
        self.target = target
        self.terminalID = terminalID
        self.workspaceID = workspaceID
    }

    /// The live (not ended) sessions of an `activity_sessions_list` result, newest action first.
    ///
    /// - Parameter result: The host's answer.
    /// - Returns: The sessions not ended, newest action first.
    public static func live(from result: [String: Any]) -> [ComputerUseLiveSession] {
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
