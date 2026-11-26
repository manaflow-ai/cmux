/// Builds the terminal-mode reset emitted between a remote PTY and a local SSH prompt.
public struct SSHTerminalModeResetSequence: Sendable {
    /// Creates a terminal-mode reset sequence builder.
    public init() {}

    /// The same reset as ``shellPrintfFormat``, encoded for direct terminal
    /// parser injection after a local foreground process is reaped.
    public var terminalBytes: [UInt8] {
        Array("\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1004l".utf8)
            + Array("\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1016l".utf8)
            + Array("\u{1b}[?2004l\u{1b}[999<u\u{1b}[0;1=u\u{1b}[>m".utf8)
            + Array("\u{1b}[?2031l\u{1b}[?2048l\u{1b}[?2026l".utf8)
    }

    /// A `printf` format that disables input and reporting modes a remote TUI may leave enabled.
    ///
    /// The value uses shell `printf` escapes rather than literal control bytes
    /// so generated startup scripts remain readable and safely quotable.
    public var shellPrintfFormat: String {
        var format = "\\033[?1000l\\033[?1002l\\033[?1003l\\033[?1004l"
        format += "\\033[?1005l\\033[?1006l\\033[?1015l\\033[?1016l"
        format += "\\033[?2004l\\033[999<u\\033[0;1=u\\033[>m"
        format += "\\033[?2031l\\033[?2048l\\033[?2026l"
        return format
    }
}
