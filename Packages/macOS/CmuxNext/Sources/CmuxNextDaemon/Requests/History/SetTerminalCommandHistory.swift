import Foundation

/// `set-terminal-command-history {enabled, retention_days?}`
/// (`terminal-command-history-v1`): turns the daemon's terminal command
/// history on or off and sets how many days it keeps commands. The switch is
/// off by default and after every daemon start; the retention is stored by
/// the daemon (default 30). Trusted local connections only.
public struct SetTerminalCommandHistoryRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var enabled: Bool
        public var retentionDays: Int

        public init(enabled: Bool, retentionDays: Int) {
            self.enabled = enabled
            self.retentionDays = retentionDays
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case retentionDays = "retention_days"
        }
    }

    public static let command = "set-terminal-command-history"
    public static let requiredCapability: String? = DaemonCapabilities.shared.terminalCommandHistory
    public var enabled: Bool
    public var retentionDays: Int?

    public init(enabled: Bool, retentionDays: Int? = nil) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
}

extension DaemonConnection {
    @discardableResult
    public func setTerminalCommandHistory(enabled: Bool, retentionDays: Int?) async throws -> SetTerminalCommandHistoryRequest.Response {
        try await request(SetTerminalCommandHistoryRequest(enabled: enabled, retentionDays: retentionDays))
    }
}
