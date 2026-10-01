import Foundation

/// One workspace's status (`WorkspaceStatusSnapshot`, resource API v2
/// `workspace_status`): keyed status entries in insertion order, one
/// progress value, and the newest log line. Agents and scripts write it with
/// `cmux workspace status|progress|log`; the sidebar row draws it.
public struct WorkspaceStatusSnapshot: Sendable, Hashable, Decodable {
    /// Public workspace id (`ws_…`), the raw tree's `resource_id`.
    public var workspaceID: ResourceID
    public var entries: [Entry]
    public var progress: Progress?
    /// Retained log lines (at most 200).
    public var logCount: Int
    public var lastLog: LogLine?

    /// One `workspace status set` entry.
    public struct Entry: Sendable, Hashable, Decodable {
        public var key: String
        public var text: String
        /// SF Symbol name.
        public var icon: String?
        /// Palette token or `#RRGGBB[AA]`.
        public var color: String?

        public init(key: String, text: String, icon: String? = nil, color: String? = nil) {
            self.key = key
            self.text = text
            self.icon = icon
            self.color = color
        }
    }

    /// `workspace progress set`: `value` in 0...1, nil for indeterminate.
    public struct Progress: Sendable, Hashable, Decodable {
        public var value: Double?
        public var label: String?

        public init(value: Double?, label: String? = nil) {
            self.value = value
            self.label = label
        }
    }

    /// One `workspace log` line.
    public struct LogLine: Sendable, Hashable, Decodable {
        /// `info`, `progress`, `success`, `warning`, or `error`.
        public var level: String
        public var source: String?
        public var text: String

        public init(level: String, source: String? = nil, text: String) {
            self.level = level
            self.source = source
            self.text = text
        }
    }

    public init(workspaceID: ResourceID, entries: [Entry] = [], progress: Progress? = nil, logCount: Int = 0,
                lastLog: LogLine? = nil) {
        self.workspaceID = workspaceID
        self.entries = entries
        self.progress = progress
        self.logCount = logCount
        self.lastLog = lastLog
    }

    /// Nothing to show: no entries, no progress, no log.
    public var isEmpty: Bool { entries.isEmpty && progress == nil && lastLog == nil }

    enum CodingKeys: String, CodingKey {
        case entries, progress
        case workspaceID = "workspace_id"
        case logCount = "log_count"
        case lastLog = "last_log"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decode(ResourceID.self, forKey: .workspaceID)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress)
        logCount = try c.decodeIfPresent(Int.self, forKey: .logCount) ?? 0
        lastLog = try c.decodeIfPresent(LogLine.self, forKey: .lastLog)
    }
}
