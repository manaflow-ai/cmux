import Foundation

/// `set-terminal-command-history {enabled}` (`terminal-command-journal-v1`):
/// turns the daemon's terminal command history on or off. Off by default
/// and after every daemon start; trusted local connections only.
public struct SetTerminalCommandHistoryRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var enabled: Bool
    }

    public static let command = "set-terminal-command-history"
    public static let requiredCapability: String? = DaemonCapabilities.shared.terminalCommandJournal
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

extension DaemonConnection {
    @discardableResult
    public func setTerminalCommandHistory(enabled: Bool) async throws -> Bool {
        try await request(SetTerminalCommandHistoryRequest(enabled: enabled)).enabled
    }
}
