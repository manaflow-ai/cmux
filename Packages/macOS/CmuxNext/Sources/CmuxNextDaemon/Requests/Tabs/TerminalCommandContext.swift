import Foundation

/// Reads the newest command a terminal's shell finished from its screen, as chat text
/// (`terminal-command-context`, `terminal-command-context-v1`): Fix on a failed command and
/// Send Last Output to Chat. One read when the person asks; nothing runs per output line.
public struct TerminalCommandContextRequest: DaemonRequest {
    /// What `text` asks the agent for.
    public enum Intent: String, Encodable, Sendable {
        /// The command and its output, for the person to write about.
        case context
        /// The same, asking the agent to find the cause and fix it.
        case fix
    }

    /// The terminal's newest finished command, if one can be read.
    public struct Response: Decodable, Sendable, Equatable {
        /// Nil without shell integration, on the alternate screen and while a command runs.
        public var context: Context?
    }

    /// One finished command.
    public struct Context: Decodable, Sendable, Equatable {
        /// The command line; nil when it scrolled past the rows read.
        public var command: String?
        /// Its exit status; nil when the shell reported none.
        public var exitCode: Int32?
        /// The folder it ran in (OSC 7).
        public var cwd: String?
        /// Its output, the newest rows.
        public var output: String
        /// Whether older output was left out.
        public var truncated: Bool
        /// The Markdown a chat composer takes.
        public var text: String

        enum CodingKeys: String, CodingKey {
            case command, cwd, output, truncated, text
            case exitCode = "exit_code"
        }
    }

    public static let command = "terminal-command-context"
    public static let requiredCapability: String? = DaemonCapability.terminalCommandContext.rawValue
    public var surface: SurfaceID
    public var intent: Intent

    public init(surface: SurfaceID, intent: Intent) {
        self.surface = surface
        self.intent = intent
    }
}
