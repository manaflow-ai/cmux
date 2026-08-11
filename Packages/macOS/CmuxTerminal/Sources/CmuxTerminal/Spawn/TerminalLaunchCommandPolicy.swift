import Foundation

/// Ghostty's parsed `command` configuration, with its launch form fixed at
/// the configuration boundary.
///
/// This parser follows `Command.parseCLI` in
/// `ghostty/src/config/command.zig`. Direct mode splits on each literal space.
/// Quotes have no grouping meaning and repeated spaces create empty arguments.
public struct GhosttyConfiguredCommand: Equatable, Sendable {
    /// The launch form selected by Ghostty's command prefix.
    public let launchForm: TerminalSurfaceLaunchForm

    /// Parses one effective Ghostty `command` value.
    public init?(rawValue: String) {
        let command = rawValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        guard let separator = command.firstIndex(of: ":") else {
            guard let launchForm = TerminalSurfaceLaunchForm(command: command) else {
                return nil
            }
            self.launchForm = launchForm
            return
        }
        let prefix = String(command[..<separator])
        let payload = String(command[command.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        let launchForm: TerminalSurfaceLaunchForm?
        switch prefix {
        case "direct":
            launchForm = TerminalSurfaceLaunchForm(
                arguments: payload.components(separatedBy: " ")
            )
        case "shell":
            launchForm = TerminalSurfaceLaunchForm(command: payload)
        default:
            launchForm = TerminalSurfaceLaunchForm(command: command)
        }
        guard let launchForm else { return nil }
        self.launchForm = launchForm
    }
}

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
    ///   - surfaceCommand: A command inherited from cmux surface state.
    ///   - userGhosttyCommand: Ghostty's configured default command, if present.
    ///   - managedShellCommand: cmux's shell-integration launch command.
    ///   - resolvedShell: The executable user-shell fallback.
    /// - Returns: The exact shell-command or direct-argument launch form.
    public func resolve(
        initialCommand: String?,
        surfaceCommand: String?,
        userGhosttyCommand: GhosttyConfiguredCommand?,
        managedShellCommand: String?,
        resolvedShell: String?
    ) -> TerminalSurfaceLaunchForm? {
        for candidate in [initialCommand, surfaceCommand] {
            if let candidate, !candidate.isEmpty {
                return TerminalSurfaceLaunchForm(command: candidate)
            }
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
