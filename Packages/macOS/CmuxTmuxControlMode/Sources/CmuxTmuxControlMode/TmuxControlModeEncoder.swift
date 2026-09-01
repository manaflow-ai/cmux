import Foundation

/// Builders for the tmux commands cmux writes to the control-mode gateway's stdin.
///
/// In control mode the client drives tmux by writing ordinary tmux commands
/// (one per line). These helpers produce those command lines (without the
/// trailing newline). Pure and unit-testable.
public enum TmuxControlModeEncoder {
    /// Capture a pane's full scrollback + visible screen, with SGR escapes, for
    /// the initial snapshot. Mirrors iTerm2's control-mode attach behavior.
    /// `-p` to stdout, `-e` keep escape sequences, and `-S -`/`-E '-'` from
    /// start to end of history. `-N` preserves trailing spaces, which are part
    /// of the authoritative cell grid. Do not use `-J`: joining wrapped rows
    /// changes the visual grid and corrupts alternate-screen TUIs during
    /// replay.
    public static func capturePane(paneID: String) -> String {
        // The quoted `-` matters. tmux's command parser treats an unquoted
        // `-E -` as a missing option argument on current releases.
        "capture-pane -t \(paneID) -p -e -N -S - -E '-'"
    }

    /// Send literal bytes to a pane as input. `-H` takes space-separated hex
    /// byte values, so this transmits the exact bytes Ghostty encoded from the
    /// user's keystrokes without tmux key-name interpretation.
    public static func sendKeys(paneID: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "send-keys -t \(paneID) -H \(hex)"
    }

    /// Splits a byte stream into bounded control commands. tmux parses one
    /// command line at a time, so allowing an unbounded paste to become one
    /// line can exceed kernel/pty buffers and stall every later response.
    public static func sendKeysCommands(
        paneID: String,
        bytes: [UInt8],
        maximumBytesPerCommand: Int = 4096
    ) -> [String] {
        guard !bytes.isEmpty else { return [] }
        let chunkSize = max(1, maximumBytesPerCommand)
        return stride(from: 0, to: bytes.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, bytes.count)
            return sendKeys(paneID: paneID, bytes: Array(bytes[start..<end]))
        }
    }

    /// Send a physical named key through tmux's key table. Named keys are
    /// needed for navigation/function keys because a local terminal's escape
    /// spelling can disagree with the pane's terminfo and mode state. Return
    /// `nil` for values that cannot be represented as one safe tmux token.
    public static func sendNamedKey(paneID: String, keyName: String) -> String? {
        guard isSafeNamedKey(keyName) else { return nil }
        return "send-keys -t \(paneID) \(tmuxQuote(keyName))"
    }

    /// Declare this control client's size so tmux sizes the window to us.
    public static func refreshClientSize(_ size: TerminalSize, windowID: String? = nil) -> String {
        let dimensions = "\(size.columns)x\(size.rows)"
        // tmux's per-window form is one argument containing a colon. The
        // command parser requires that argument to be quoted; without quotes
        // tmux reports "bad size argument" and no resize reaches the pane.
        let target = windowID.map { tmuxQuote("\($0):\(dimensions)") } ?? dimensions
        return "refresh-client -C \(target)"
    }

    /// Enable tmux's bounded flow-control queue for this client. A paused pane
    /// is repaired from an authoritative capture before output resumes.
    public static func enableFlowControl(pauseAfterSeconds: Int = 30) -> String {
        "refresh-client -f pause-after=\(max(1, pauseAfterSeconds))"
    }

    /// Pause one pane's output cursor while a capture and state query form one
    /// replacement transaction. The quoted argument is required by tmux's
    /// `-A` parser.
    public static func pausePaneOutput(paneID: String) -> String {
        "refresh-client -A \"\(paneID):pause\""
    }

    /// Continue one pane after the replacement snapshot is ready.
    public static func continuePaneOutput(paneID: String) -> String {
        "refresh-client -A \"\(paneID):continue\""
    }

    /// Query the pane's alternate-screen flag and foreground command in one
    /// response. The command is part of the resize policy because an inline TUI
    /// can stay on the primary screen and never emit an alternate-screen mode.
    public static func queryPaneForeground(paneID: String) -> String {
        "display-message -p -t \(paneID) -F \"#{alternate_on}|#{pane_current_command}\""
    }

    /// Stable subscription name for a pane's foreground state. Pane ids are
    /// server-assigned `%N` values, so keeping only the numeric suffix makes
    /// the notification routing unambiguous and shell-safe.
    public static func foregroundSubscriptionName(paneID: String) -> String {
        "cmux_harbor_reflow_" + paneID.drop(while: { $0 == "%" })
    }

    /// Subscribe to live foreground changes. tmux emits the current value on
    /// subscribe and every time the command or alternate screen changes.
    public static func subscribePaneForeground(paneID: String) -> String {
        let name = foregroundSubscriptionName(paneID: paneID)
        return "refresh-client -B \"\(name):\(paneID):#{alternate_on}|#{pane_current_command}\""
    }

    /// Remove the live foreground subscription during teardown.
    public static func unsubscribePaneForeground(paneID: String) -> String {
        "refresh-client -B \(foregroundSubscriptionName(paneID: paneID))"
    }

    /// Query the terminal state that `capture-pane` does not include.
    public static func queryPaneState(paneID: String) -> String {
        "display-message -p -t \(paneID) -F \""
            + "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
            + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
            + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
            + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
            + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_height=#{pane_height},"
            + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
            + "mouse_standard_flag=#{mouse_standard_flag},"
            + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag}\""
    }

    /// List the panes of the attached session's current window, active flag
    /// first, so we can resolve which pane to render.
    /// Each result line is `<pane_active>:<pane_id>`, e.g. `1:%3`.
    public static func listActivePanes() -> String {
        "list-panes -F '#{pane_active}:#{pane_id}'"
    }

    private static func isSafeNamedKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-+_.,:/?@#<>!*\\"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func tmuxQuote(_ value: String) -> String {
        // Single quotes are rejected above. This keeps tmux's command parser
        // from interpreting a key name as multiple commands or arguments.
        "'" + value + "'"
    }
}
