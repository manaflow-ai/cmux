import Foundation

/// Builders for the tmux commands cmux writes to the `-CC` gateway's stdin.
///
/// In control mode the client drives tmux by writing ordinary tmux commands
/// (one per line). These helpers produce those command lines (without the
/// trailing newline). Pure and unit-testable.
public enum TmuxControlModeEncoder {
    /// Capture a pane's full scrollback + visible screen, with SGR escapes, for
    /// the initial snapshot. Mirrors iTerm2's control-mode attach behavior.
    /// `-p` to stdout, `-e` keep escape sequences, `-J` join wrapped lines and
    /// preserve trailing spaces, `-S -`/`-E -` from start to end of history.
    public static func capturePane(paneID: String) -> String {
        "capture-pane -t \(paneID) -p -e -J -S - -E -"
    }

    /// Send literal bytes to a pane as input. `-H` takes space-separated hex
    /// byte values, so this transmits the exact bytes Ghostty encoded from the
    /// user's keystrokes without tmux key-name interpretation.
    public static func sendKeys(paneID: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "send-keys -t \(paneID) -H \(hex)"
    }

    /// Declare this control client's size so tmux sizes the window to us.
    public static func refreshClientSize(_ size: TerminalSize) -> String {
        "refresh-client -C \(size.columns)x\(size.rows)"
    }

    /// Detach this control client (the tmux session keeps running). tmux then
    /// emits `%exit`, which ends the control-mode session.
    public static func detachClient() -> String {
        "detach-client"
    }

    /// List the panes of the attached session's current window, active flag
    /// first, so we can resolve which pane to render.
    /// Each result line is `<pane_active>:<pane_id>`, e.g. `1:%3`.
    public static func listActivePanes() -> String {
        "list-panes -F '#{pane_active}:#{pane_id}'"
    }
}
