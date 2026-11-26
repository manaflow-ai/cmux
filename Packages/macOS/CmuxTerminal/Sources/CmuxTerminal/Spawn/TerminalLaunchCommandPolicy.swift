/// Selects the command passed to Ghostty when creating a terminal surface.
public struct TerminalLaunchCommandPolicy: Sendable {
    /// Creates a launch-command policy.
    public init() {}

    /// Resolves the first non-empty command in launch-precedence order.
    ///
    /// Explicit per-surface commands win first. When Ghostty's app config owns
    /// the default command, this returns `nil` so Ghostty preserves its parsed
    /// direct-versus-shell execution semantics. Otherwise cmux supplies its
    /// shell-integration wrapper or resolved user-shell fallback.
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
        for candidate in [managedShellCommand, resolvedShell] {
            if let candidate, !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }
}
