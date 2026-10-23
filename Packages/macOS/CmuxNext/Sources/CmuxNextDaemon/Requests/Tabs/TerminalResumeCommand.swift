import Foundation

/// Reads, sets or clears the resume command of one hosted terminal
/// (`terminal-resume-command`, `resume-command`): the line a person chose
/// for it, typed on the new prompt without a newline when the daemon
/// respawns the terminal. Name the terminal by `surface` (a PTY tab showing
/// it) or `terminal_id` (host id or public `term_` id).
public struct TerminalResumeCommandRequest: DaemonRequest {
    /// The stored resume command after the request.
    public struct Response: Decodable, Sendable, Equatable {
        /// The terminal's host id.
        public var terminalID: TerminalID
        /// The stored command, nil when none is set.
        public var command: String?

        enum CodingKeys: String, CodingKey {
            case command
            case terminalID = "terminal_id"
        }
    }

    /// What the request does to the stored command.
    public enum Change: Sendable, Hashable {
        /// Only reads it.
        case read
        /// Stores this line (the daemon trims it and refuses an empty or
        /// multi-line one).
        case set(String)
        /// Removes it.
        case clear
    }

    public static let command = "terminal-resume-command"
    public static let requiredCapability: String? = DaemonCapability.resumeCommand.rawValue
    public var target: SetTerminalKeepRequest.Target
    public var change: Change

    /// - Parameters:
    ///   - target: The terminal, by PTY surface or terminal id.
    ///   - change: Read (the default), set or clear.
    public init(_ target: SetTerminalKeepRequest.Target, change: Change = .read) {
        self.target = target
        self.change = change
    }

    enum CodingKeys: String, CodingKey { case surface, terminalID, command }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .surface(let surface): try c.encode(surface, forKey: .surface)
        case .terminal(let terminal): try c.encode(terminal, forKey: .terminalID)
        }
        switch change {
        case .read: break
        case .set(let command): try c.encode(command, forKey: .command)
        // An explicit null clears; an absent field only reads.
        case .clear: try c.encodeNil(forKey: .command)
        }
    }
}
