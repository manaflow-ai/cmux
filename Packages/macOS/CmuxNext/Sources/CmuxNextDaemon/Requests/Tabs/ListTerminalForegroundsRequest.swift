import Foundation

/// `list-terminal-foregrounds` (`terminal-foreground-v1`): every live PTY surface's foreground
/// program, read from the daemon's memory. Seeds ``TerminalForegrounds`` at connect, as
/// `list-agents` seeds the agents; `terminal-foreground-changed` events keep it current.
public struct ListTerminalForegroundsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var foregrounds: [TerminalForeground]
    }

    public static let command = "list-terminal-foregrounds"
    public init() {}
}
