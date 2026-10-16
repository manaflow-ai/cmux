import Foundation

/// Builds a line-safe tmux control-mode command that sets one pane title.
///
/// The title is deliberately format-escaped before quoting: tmux expands `#`
/// format markers in `select-pane -T` arguments, even when the argument is
/// quoted for its command parser.
public enum RemoteTmuxPaneTitleCommand {
    /// Returns a `select-pane -T` command, or `nil` when the pane id or title
    /// could break the line-oriented control stream.
    public static func make(paneID: Int, title: String) -> String? {
        guard paneID >= 0 else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let literal = trimmed.replacingOccurrences(of: "#", with: "##")
        return "select-pane -t %\(paneID) -T \(singleQuoted(literal))"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
