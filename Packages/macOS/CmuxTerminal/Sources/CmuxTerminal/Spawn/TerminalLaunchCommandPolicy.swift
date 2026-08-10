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
    ///   - surfaceCommand: A command inherited from cmux surface state.
    ///   - userGhosttyCommand: Ghostty's configured default command, if present.
    ///   - managedShellCommand: cmux's shell-integration launch command.
    ///   - resolvedShell: The executable user-shell fallback.
    /// - Returns: The exact shell-command or direct-argument launch form.
    public func resolve(
        initialCommand: String?,
        surfaceCommand: String?,
        userGhosttyCommand: String?,
        managedShellCommand: String?,
        resolvedShell: String?
    ) -> TerminalSurfaceLaunchForm? {
        for candidate in [initialCommand, surfaceCommand] {
            if let candidate, !candidate.isEmpty {
                return TerminalSurfaceLaunchForm(command: candidate)
            }
        }
        if let userGhosttyCommand {
            return TerminalSurfaceLaunchForm(
                ghosttyConfiguredCommand: userGhosttyCommand
            )
        }
        for candidate in [managedShellCommand, resolvedShell] {
            if let candidate, !candidate.isEmpty {
                return TerminalSurfaceLaunchForm(command: candidate)
            }
        }
        return nil
    }
}

extension TerminalSurfaceLaunchForm {
    init?(ghosttyConfiguredCommand rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        guard let separator = command.firstIndex(of: ":") else {
            self.init(command: command)
            return
        }
        let prefix = String(command[..<separator])
        let payload = String(command[command.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        switch prefix {
        case "direct":
            let arguments = payload.components(separatedBy: " ")
            self.init(arguments: arguments)
        case "shell":
            self.init(command: payload)
        default:
            self.init(command: command)
        }
    }
}
