import Foundation

/// Builds a line-safe tmux control-mode command that sets one pane title.
///
/// The title is deliberately format-escaped before quoting: tmux expands `#`
/// format markers in `select-pane -T` arguments, even when the argument is
/// quoted for its command parser.
public struct RemoteTmuxPaneTitleCommand: Equatable, Sendable {
    /// The line-safe control-mode command.
    public let line: String

    /// Creates a command, failing if the pane id or title is unsafe for the control stream.
    ///
    /// - Parameter paneID: The nonnegative tmux pane identifier.
    /// - Parameter title: The pane title, trimmed before being encoded.
    public init?(paneID: Int, title: String) {
        guard paneID >= 0 else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let literal = trimmed.replacingOccurrences(of: "#", with: "##")
        let quoted = "'" + literal.replacingOccurrences(of: "'", with: "'\\''") + "'"
        line = "select-pane -t %\(paneID) -T \(quoted)"
    }
}
