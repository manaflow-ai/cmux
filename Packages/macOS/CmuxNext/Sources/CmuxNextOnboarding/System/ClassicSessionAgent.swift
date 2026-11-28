public import Foundation

/// A Claude Code or Codex session classic recorded on a terminal
/// (`terminal.agent`), to resume as a chat.
public nonisolated struct ClassicSessionAgent: Codable, Equatable, Sendable {
    /// The acpmux harness: `claude` or `codex`.
    public let harness: String
    /// The harness's own session id.
    public let sessionID: String
    public let workingDirectory: String?

    public init(harness: String, sessionID: String, workingDirectory: String?) {
        self.harness = harness
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
    }
}
