/// Declarative startup behavior for an ordinary local terminal surface.
public struct TerminalShellStartupConfiguration: Equatable, Sendable {
    /// Login or non-login shell invocation mode.
    public var mode: TerminalShellStartupMode

    /// Optional input sent after the shell starts.
    public var command: String?

    /// Creates a shell startup configuration.
    ///
    /// - Parameters:
    ///   - mode: Shell invocation mode. Defaults to ``TerminalShellStartupMode/login``.
    ///   - command: Optional startup input. Blank input is treated as absent.
    public init(mode: TerminalShellStartupMode = .login, command: String? = nil) {
        self.mode = mode
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = trimmed?.isEmpty == false ? trimmed : nil
    }
}
