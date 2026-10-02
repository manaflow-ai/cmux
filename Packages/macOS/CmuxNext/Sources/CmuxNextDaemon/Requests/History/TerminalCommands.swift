public import Foundation

/// One stored terminal command (`terminal-command-history-v1`). Ids and
/// times are decimal strings.
public struct TerminalCommandRow: Decodable, Sendable, Equatable {
    public var id: String
    public var terminalID: String
    public var command: String?
    public var cwd: String?
    public var exitCode: Int?
    public var startedAtMs: String
    public var durationMs: String

    enum CodingKeys: String, CodingKey {
        case id, command, cwd
        case terminalID = "terminal_id"
        case exitCode = "exit_code"
        case startedAtMs = "started_at_ms"
        case durationMs = "duration_ms"
    }
}

/// `list-terminal-commands {after_id?, limit?}`: the newest `limit`
/// unexpired commands after `after_id`, oldest first. `truncated` says older
/// rows after `after_id` were left out. `deletions` changes after a client
/// delete and `registry_id` names the store: a reader that saw other values
/// reads from the start. Expiry is not counted; a reader drops rows older
/// than `retention_days` itself.
public struct ListTerminalCommandsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var commands: [TerminalCommandRow]
        public var truncated: Bool
        public var deletions: String
        public var registryID: String
        public var retentionDays: Int

        /// Changes whenever appending after the last id would be wrong.
        public var version: String { "\(registryID)/\(deletions)" }

        enum CodingKeys: String, CodingKey {
            case commands, truncated, deletions
            case registryID = "registry_id"
            case retentionDays = "retention_days"
        }
    }

    public static let command = "list-terminal-commands"
    public var afterID: String?
    public var limit: Int?

    public init(afterID: String? = nil, limit: Int? = nil) {
        self.afterID = afterID
        self.limit = limit
    }
}

/// `delete-terminal-commands`: exactly one of `ids`, `started_since_ms` or
/// `all`. The daemon deletes the rows (secure delete), not hides them.
public struct DeleteTerminalCommandsRequest: DaemonRequest {
    public enum Selection: Sendable, Equatable {
        case ids([String])
        /// Commands that started at or after this time.
        case startedSince(Date)
        case all
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var deleted: UInt64
    }

    public static let command = "delete-terminal-commands"
    public var selection: Selection

    public init(_ selection: Selection) {
        self.selection = selection
    }

    enum CodingKeys: String, CodingKey {
        case ids, all
        case startedSinceMs = "started_since_ms"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch selection {
        case .ids(let ids): try container.encode(ids, forKey: .ids)
        case .startedSince(let date):
            let ms = max(0, (date.timeIntervalSince1970 * 1000).rounded())
            try container.encode(String(UInt64(ms)), forKey: .startedSinceMs)
        case .all: try container.encode(true, forKey: .all)
        }
    }
}
