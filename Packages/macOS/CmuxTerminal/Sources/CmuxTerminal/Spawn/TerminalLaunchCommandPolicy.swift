/// Selects the command passed to Ghostty when creating a terminal surface.
public struct TerminalLaunchCommandPolicy: Sendable {
    /// Creates a launch-command policy.
    public init() {}

    /// Builds the Ghostty app-level default command for a directly launchable shell.
    ///
    /// Ghostty's embedded per-surface command is always shell-expanded, while
    /// its app configuration preserves the `direct:` command form. zsh accepts
    /// an explicit login flag, so cmux can bypass shell expansion without
    /// changing login-shell startup behavior.
    ///
    /// - Parameter resolvedShell: The executable user-shell fallback.
    /// - Returns: A Ghostty app command, or `nil` when the shell needs the
    ///   existing per-surface fallback.
    public func ghosttyAppCommand(resolvedShell: String?) -> String? {
        guard let resolvedShell,
              !resolvedShell.isEmpty,
              !resolvedShell.contains(where: \.isWhitespace),
              resolvedShell.split(separator: "/").last == "zsh"
        else { return nil }
        return "direct:\(resolvedShell) -l"
    }

    /// Resolves the first non-empty command in launch-precedence order.
    ///
    /// Explicit per-surface commands win first. When Ghostty's app config owns
    /// the default command, either from the user or cmux's direct zsh fallback,
    /// this returns `nil` so Ghostty preserves its parsed direct-versus-shell
    /// execution semantics. Otherwise cmux supplies its shell-integration
    /// wrapper or resolved user-shell fallback.
    ///
    /// - Parameters:
    ///   - initialCommand: The command requested for this surface.
    ///   - surfaceCommand: A command inherited from cmux surface state.
    ///   - hasUserGhosttyCommand: Whether Ghostty's app config owns the default command.
    ///   - managedShellCommand: cmux's shell-integration launch command.
    ///   - resolvedShell: The executable user-shell fallback.
    /// - Returns: A per-surface command override, or `nil` to inherit Ghostty's command.
    public func resolve(
        initialCommand: String?,
        surfaceCommand: String?,
        hasUserGhosttyCommand: Bool,
        managedShellCommand: String?,
        resolvedShell: String?
    ) -> String? {
        for candidate in [initialCommand, surfaceCommand] {
            if let candidate, !candidate.isEmpty {
                return candidate
            }
        }
        if hasUserGhosttyCommand { return nil }
        if let managedShellCommand, !managedShellCommand.isEmpty {
            return managedShellCommand
        }
        if ghosttyAppCommand(resolvedShell: resolvedShell) != nil {
            return nil
        }
        if let resolvedShell, !resolvedShell.isEmpty {
            return resolvedShell
        }
        return nil
    }
}
