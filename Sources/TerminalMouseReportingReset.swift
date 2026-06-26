import Foundation

/// Computes the DECRST sequence that clears mouse-tracking modes left stuck
/// "on" by a program that exited without disabling them.
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
/// point, the just-finished program left it stuck, and cmux feeds `disableSequence`
/// back into the terminal parser (never the pty, so the shell is undisturbed) to
/// clear the modes.
struct TerminalMouseReportingReset {
    /// Whether the terminal still reports mouse events at the command boundary.
    let mouseReportingActive: Bool

    /// The DECRST disable sequence to feed into the terminal parser, or `nil`
    /// when mouse reporting is already off and there is nothing to clear.
    var disableSequence: String? {
        guard mouseReportingActive else { return nil }
        return Self.allMouseModesDisableSequence
    }

    /// DECRST sequences that disable every mouse tracking and mouse encoding
    /// mode: X10 (9), VT200/normal (1000), highlight (1001), button/cell-motion
    /// (1002), any-event/all-motion (1003), and the UTF-8 (1005), SGR (1006),
    /// urxvt (1015) and SGR-pixel (1016) report encodings.
    static let allMouseModesDisableSequence =
        "\u{1b}[?9l"
        + "\u{1b}[?1000l"
        + "\u{1b}[?1001l"
        + "\u{1b}[?1002l"
        + "\u{1b}[?1003l"
        + "\u{1b}[?1005l"
        + "\u{1b}[?1006l"
        + "\u{1b}[?1015l"
        + "\u{1b}[?1016l"
}
