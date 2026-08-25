/// Builds the terminal-mode reset emitted between a remote PTY and a local SSH prompt.
public struct SSHTerminalModeResetSequence: Sendable {
    /// Creates a terminal-mode reset sequence builder.
    public init() {}

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
