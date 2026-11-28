import Foundation

/// Reads the newest command the shell of one live terminal finished
/// (`terminal-last-command`, `terminal-last-command-v1`), for Run Last
/// Command Again. Name the terminal by `surface` (a PTY tab showing it) or
/// `terminal_id` (host id or public `term_` id).
public struct TerminalLastCommandRequest: DaemonRequest {
    /// The terminal and its last command, if any.
    public struct Response: Decodable, Sendable, Equatable {
        /// The terminal's host id.
        public var terminalID: TerminalID
        /// The newest finished command; nil while recording is off, for an
        /// incognito terminal and before the shell finished a command.
        public var lastCommand: LastCommand?

        enum CodingKeys: String, CodingKey {
            case terminalID = "terminal_id"
            case lastCommand = "last_command"
        }
    }

    /// One finished command line.
    public struct LastCommand: Decodable, Sendable, Equatable {
        /// The command line as the shell submitted it.
        public var command: String
        /// Its exit status; nil when the shell reported none.
        public var exitCode: Int32?
        /// When it started, Unix epoch milliseconds as a decimal string.
        public var startedAtMs: String
        /// When it ended, Unix epoch milliseconds as a decimal string.
        public var endedAtMs: String

        enum CodingKeys: String, CodingKey {
            case command
            case exitCode = "exit_code"
            case startedAtMs = "started_at_ms"
            case endedAtMs = "ended_at_ms"
        }
    }

    public static let command = "terminal-last-command"
    public static let requiredCapability: String? = DaemonCapability.terminalLastCommand.rawValue
    public var target: SetTerminalKeepRequest.Target

    /// - Parameter target: The terminal, by PTY surface or terminal id.
    public init(_ target: SetTerminalKeepRequest.Target) {
        self.target = target
    }

    enum CodingKeys: String, CodingKey { case surface, terminalID }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .surface(let surface): try c.encode(surface, forKey: .surface)
        case .terminal(let terminal): try c.encode(terminal, forKey: .terminalID)
        }
    }
}
