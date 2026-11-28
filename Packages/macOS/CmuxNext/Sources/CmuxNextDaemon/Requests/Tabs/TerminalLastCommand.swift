import Foundation

/// Reads the newest command the shell of one live terminal finished
/// (`terminal-last-command`, `terminal-last-command-v1`), for Run Last
/// Command Again. Name the terminal by `surface` (a PTY tab showing it) or
/// `terminal_id` (host id or public `term_` id).
public struct TerminalLastCommandRequest: DaemonRequest {
    public typealias Response = TerminalLastCommandResult

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
