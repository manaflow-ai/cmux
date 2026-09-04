/// Builds shell-specific commands used by managed cmux integration.
///
/// The builder keeps quoting and login-mode decisions in one constructable
/// service. Its instance surface is injectable and testable without adding
/// another static utility namespace to ``TerminalSurface``.
public struct TerminalShellIntegrationCommandBuilder: Sendable {
    private let quote: @Sendable (String) -> String

    /// Creates a command builder.
    ///
    /// - Parameter quote: Shell-quoting seam. The default uses cmux's existing
    ///   POSIX quoting contract.
    public init(quote: @escaping @Sendable (String) -> String = {
        TerminalSurface.shellSingleQuoted($0)
    }) {
        self.quote = quote
    }

    /// Returns the managed fish launch command for the requested login mode.
    public func managedFishShellCommand(
        shell: String,
        mode: TerminalShellStartupMode = .login
    ) -> String {
        let initCommand = #"source "$CMUX_FISH_INTEGRATION_FILE""#
        let flags = mode == .login ? "-il" : "-i"
        let arguments = "\(flags) --init-command \(quote(initCommand))"
        if mode == .nonLogin {
            return TerminalShellStartupPolicy().nonLoginShellCommand(
                shell: shell,
                arguments: arguments
            )
        }
        return "\(quote(shell)) \(arguments)"
    }

    /// Returns the managed nushell command for the requested login mode.
    public func managedNushellShellCommand(
        shell: String,
        startupPayload: String,
        mode: TerminalShellStartupMode = .login
    ) -> String {
        let modeFlag = mode == .login ? "-l" : "-i"
        return "\(quote(shell)) \(modeFlag) -e \(quote(startupPayload))"
    }
}
