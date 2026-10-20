import Foundation

/// Sets or clears the resume command of the terminal a PTY tab shows
/// (`set-terminal-resume-command`, `terminal-resume-command-v1`): the command
/// the terminal's new shell runs when the terminal respawns after a host loss
/// or restarts (`restart-tab`). The daemon stores it with the terminal and
/// shows it on every tab of the terminal (``TabSnapshot/resumeCommand``).
///
/// `command` is always sent: a string sets it, nil (null) clears it. The
/// daemon trims it and refuses a control character, since a newline would
/// run part of it.
///
/// ```swift
/// try await connection.request(SetTerminalResumeCommandRequest(surface: tab.surface, command: "claude --resume abc"))
/// ```
public struct SetTerminalResumeCommandRequest: DaemonRequest {
    /// The stored command, nil once cleared.
    public struct Response: Decodable, Sendable, Equatable {
        /// The terminal's host id.
        public var terminalID: TerminalID
        /// The terminal's public id (`term_…`).
        public var terminalResourceID: ResourceID?
        /// The command now stored (trimmed), or nil.
        public var resumeCommand: String?

        enum CodingKeys: String, CodingKey {
            case terminalID = "terminal_id"
            case terminalResourceID = "terminal_resource_id"
            case resumeCommand = "resume_command"
        }
    }

    public static let command = "set-terminal-resume-command"
    public static let requiredCapability: String? = DaemonCapabilities.shared.terminalResumeCommand
    /// A PTY tab showing the terminal.
    public var surface: SurfaceID
    /// The command to store, or nil to clear it.
    public var command: String?

    /// - Parameters:
    ///   - surface: A PTY tab showing the terminal.
    ///   - command: The command to store; nil clears it.
    public init(surface: SurfaceID, command: String?) {
        self.surface = surface
        self.command = command
    }

    enum CodingKeys: String, CodingKey { case surface, command }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        // Null clears; the key is never left out.
        try c.encode(command, forKey: .command)
    }
}
