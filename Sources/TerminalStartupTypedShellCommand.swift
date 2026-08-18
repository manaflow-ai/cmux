import CMUXAgentLaunch

/// Renders a generated POSIX command for a terminal's interactive shell.
///
/// POSIX shells receive the command verbatim. Nushell receives a portable
/// `/bin/sh` envelope because it cannot parse cmux's POSIX command builders.
/// Launcher-script inputs (`/bin/zsh '<script>'`) are already shell-neutral and
/// should not use this renderer.
struct TerminalStartupTypedShellCommand {
    /// Dialect of the shell that will parse the rendered input.
    let dialect: TerminalStartupShellDialect

    /// Creates a renderer for the selected shell dialect.
    ///
    /// The default follows the local login shell cmux uses for new surfaces;
    /// remote callers should pass ``TerminalStartupShellDialect/remoteHost``.
    init(dialect: TerminalStartupShellDialect = .loginShell) {
        self.dialect = dialect
    }

    /// Renders `posixCommand` for the selected shell dialect.
    func typedInput(posixCommand: String) -> String {
        switch dialect {
        case .posix:
            return posixCommand
        case .nushell:
            return NushellTypedShellCommand().wrapping(posixCommand: posixCommand)
        }
    }
}
