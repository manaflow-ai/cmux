public import Foundation

/// The daemon's `list-terminal-commands` reply. The request is generated from
/// `cmux-tui/spec/sdk-schema.json`.
public struct ListTerminalCommandsResponse: Decodable, Sendable, Equatable {
    public var commands: [TerminalCommandRow]
    public var truncated: Bool
    public var deletions: String
    public var registryID: String
    public var retentionDays: Int

    /// Changes whenever appending after the last id would be wrong.
    public var version: String { "\(registryID)/\(deletions)" }

    public init(
        commands: [TerminalCommandRow],
        truncated: Bool,
        deletions: String,
        registryID: String,
        retentionDays: Int
    ) {
        self.commands = commands
        self.truncated = truncated
        self.deletions = deletions
        self.registryID = registryID
        self.retentionDays = retentionDays
    }

    enum CodingKeys: String, CodingKey {
        case commands, truncated, deletions
        case registryID = "registry_id"
        case retentionDays = "retention_days"
    }
}

extension ListTerminalCommandsRequest {
    public typealias Response = ListTerminalCommandsResponse
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
            // A date before 1970 or past UInt64 clamps instead of trapping.
            let ms = UInt64(exactly: max(0, (date.timeIntervalSince1970 * 1000).rounded())) ?? UInt64.max
            try container.encode(String(ms), forKey: .startedSinceMs)
        case .all: try container.encode(true, forKey: .all)
        }
    }
}
