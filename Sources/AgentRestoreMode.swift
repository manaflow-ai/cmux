import Foundation

/// Describes whether restoring an agent continues a session or starts its captured command again.
enum AgentRestoreMode: String, Codable, Equatable, Sendable {
    /// Continue the upstream conversation identified by `sessionId`.
    case resumeSession

    /// Relaunch the sanitized original command with no upstream conversation identity.
    case relaunchCommand
}
