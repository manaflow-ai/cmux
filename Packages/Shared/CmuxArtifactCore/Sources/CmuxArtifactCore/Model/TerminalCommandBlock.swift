import Foundation

/// One command/output unit of a plain-terminal session, the terminal
/// analogue of a chat message.
///
/// A shell session is not a request/response transcript, so the chat view of
/// a terminal renders these blocks as a single-column monospace log (not
/// opposing bubbles). Blocks are produced by ``OSC133CommandParser`` from a
/// shell that emits OSC 133 semantic-prompt marks; when marks are absent the
/// session degrades to a raw rolling log instead (handled by the producer,
/// not here).
public struct TerminalCommandBlock: Sendable, Equatable, Identifiable, Codable {
    /// Stable identity within a session (the command's ordinal).
    public let id: Int

    /// The command line the user typed (the text between the OSC 133 `B` and
    /// `C` marks), trimmed. Empty for a bare prompt with no command.
    public let command: String

    /// The command's exit code once it finished (`D;<exit>`), or `nil` while
    /// it is still running.
    public var exitCode: Int?

    /// Whether the command is still producing output (between `C` and `D`).
    public var isRunning: Bool

    /// Whether the command entered a full-screen / alt-screen program (vim,
    /// htop, less). The chat shows an interactive-program card for these
    /// rather than trying to render the screen as output.
    public var isInteractive: Bool

    /// Accumulated command output (between `C` and `D`), with carriage-return
    /// progress redraws already folded to their final per-line state.
    ///
    /// Declared LAST so the synthesized `Equatable` compares the cheap scalar
    /// fields first and only does the full string comparison when they match —
    /// a streaming block diffs against its prior self every output tick.
    public var output: String

    /// Creates a command block.
    public init(
        id: Int,
        command: String,
        output: String = "",
        exitCode: Int? = nil,
        isRunning: Bool = true,
        isInteractive: Bool = false
    ) {
        self.id = id
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.isRunning = isRunning
        self.isInteractive = isInteractive
    }

    /// Whether the command finished with a non-zero status.
    public var failed: Bool {
        guard let exitCode else { return false }
        return exitCode != 0
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case output
        case exitCode = "exit_code"
        case isRunning = "is_running"
        case isInteractive = "is_interactive"
    }
}
