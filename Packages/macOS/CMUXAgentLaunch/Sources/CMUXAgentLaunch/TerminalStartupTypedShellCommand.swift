/// Renders a generated POSIX command for a terminal's interactive shell.
///
/// POSIX shells receive the command verbatim. Nushell receives a portable
/// `/bin/sh` envelope because it cannot parse cmux's POSIX command builders.
/// Launcher-script inputs (`/bin/zsh '<script>'`) are already shell-neutral and
/// should not use this renderer.
nonisolated public struct TerminalStartupTypedShellCommand: Sendable {
    private let dialect: TerminalStartupShellDialect

    /// Creates a renderer for the selected shell dialect.
    ///
    /// The default follows the local login shell cmux uses for new surfaces;
    /// remote callers should pass ``TerminalStartupShellDialect/remoteHost``.
    ///
    /// - Parameter dialect: The syntax family that will parse the result.
    public init(dialect: TerminalStartupShellDialect = .loginShell()) {
        self.dialect = dialect
    }

    /// Renders a POSIX command for the selected shell dialect.
    ///
    /// - Parameter posixCommand: The generated POSIX command body.
    /// - Returns: The original command for POSIX shells or a Nushell-safe
    ///   `/bin/sh` envelope.
    public func typedInput(posixCommand: String) -> String {
        switch dialect {
        case .posix:
            return posixCommand
        case .nushell:
            return NushellTypedShellCommand().wrapping(posixCommand: posixCommand)
        }
    }
}
