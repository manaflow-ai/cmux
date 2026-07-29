public import CmuxFoundation
public import Foundation

/// Executes worktree commands on one host.
///
/// Implementations own command routing. The local implementation wraps
/// ``CmuxFoundation/CommandRunning``; an SSH implementation can route the same
/// calls remotely while preserving ``WorktreeIdentity`` values.
public protocol WorktreeExecutionHost: Sendable {
    /// The stable identity of this execution host.
    var id: WorktreeHostID { get }

    /// The host's absolute home-directory path.
    var homeDirectory: String { get }

    /// Returns whether commands can currently be routed to the host.
    /// - Returns: `true` only when executing a command is currently possible.
    func isAvailable() async -> Bool

    /// Runs a command on the host and captures its output.
    /// - Parameters:
    ///   - directory: The host-local working directory.
    ///   - executable: The executable name or host-local absolute path.
    ///   - arguments: Arguments passed without shell interpretation.
    ///   - environment: Environment values added for this command.
    ///   - timeout: A bounded deadline in seconds, or `nil` for no deadline.
    /// - Returns: The captured command result.
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async -> CommandResult
}
