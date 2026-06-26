import Foundation

/// Recovery for terminals that are left with mouse-tracking modes stuck "on".
///
/// A program that enables mouse reporting (an interactive SSH session, `tmux`,
/// `vim`, any TUI, …) is expected to emit the matching DECRST disable sequences
/// before it exits. When such a program is killed ungracefully — most commonly
/// when the Mac sleeps and a remote connection drops while the machine is
/// asleep — those disable sequences are never sent, so the terminal keeps
/// reporting mouse movement. Back at the shell prompt that reporting is echoed
/// as literal escape sequences: "after returning from sleep, the terminal
/// starts printing mouse movements" (https://github.com/manaflow-ai/cmux/issues/6668).
///
/// cmux detects the return to a shell prompt through the OSC 133 "command
/// finished" shell-integration mark. If mouse reporting is still active at that
/// point, the just-finished program left it stuck, and cmux feeds these disable
/// sequences back into the terminal parser (never the pty, so the shell is
/// undisturbed) to clear the modes.
enum TerminalMouseReportingReset {
    /// DECRST sequences that disable every mouse tracking and mouse encoding
    /// mode: X10 (9), VT200/normal (1000), highlight (1001), button/cell-motion
    /// (1002), any-event/all-motion (1003), and the UTF-8 (1005), SGR (1006),
    /// urxvt (1015) and SGR-pixel (1016) report encodings.
    static let disableSequence =
        "\u{1b}[?9l"
        + "\u{1b}[?1000l"
        + "\u{1b}[?1001l"
        + "\u{1b}[?1002l"
        + "\u{1b}[?1003l"
        + "\u{1b}[?1005l"
        + "\u{1b}[?1006l"
        + "\u{1b}[?1015l"
        + "\u{1b}[?1016l"

    /// Returns the disable sequence when mouse reporting is still active at a
    /// command boundary (i.e. the just-finished program left it stuck), or `nil`
    /// when there is nothing to clear.
    static func sequenceToClearStuckMouseModes(mouseReportingActive: Bool) -> String? {
        guard mouseReportingActive else { return nil }
        return disableSequence
    }
}
