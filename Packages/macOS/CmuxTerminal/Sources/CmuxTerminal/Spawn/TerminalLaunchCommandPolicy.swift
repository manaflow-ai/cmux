import Foundation

/// Selects the command passed to Ghostty when creating a terminal surface.
public struct TerminalLaunchCommandPolicy: Sendable {
    /// Creates a launch-command policy.
    public init() {}

    /// Resolves the first non-empty command in launch-precedence order.
    ///
    /// Explicit per-surface commands win first. Ghostty's configured command
    /// retains its parsed direct-versus-shell execution semantics. Otherwise
    /// cmux supplies its shell-integration wrapper or resolved user-shell fallback.
    ///
    /// - Parameters:
    ///   - initialCommand: The command requested for this surface.
    ///   - surfaceCommand: A parsed command inherited from cmux surface state.
    ///   - userGhosttyCommand: Ghostty's configured default command, if present.
    ///   - managedShellCommand: cmux's shell-integration launch command.
    ///   - resolvedShell: The executable user-shell fallback.
    /// - Returns: The exact shell-command or direct-argument launch form.
    public func resolve(
        initialCommand: String?,
        surfaceCommand: GhosttyConfiguredCommand?,
        userGhosttyCommand: GhosttyConfiguredCommand?,
        managedShellCommand: String?,
        resolvedShell: String?
    ) -> TerminalSurfaceLaunchForm? {
        if let initialCommand,
           let configuredCommand = GhosttyConfiguredCommand(rawValue: initialCommand)
        {
            return configuredCommand.launchForm
        }
        if let surfaceCommand {
            return surfaceCommand.launchForm
        }
        if let userGhosttyCommand {
            return userGhosttyCommand.launchForm
        }
        for candidate in [managedShellCommand, resolvedShell] {
            if let candidate, !candidate.isEmpty {
                return TerminalSurfaceLaunchForm(command: candidate)
            }
        }
        return nil
    }
}
