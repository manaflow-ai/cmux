/// Pure launch decisions for declarative shell-startup settings.
public struct TerminalShellStartupPolicy: Sendable {
    /// Creates a shell-startup decision policy.
    public init() {}

    /// Resolves whether declarative shell startup owns a surface.
    ///
    /// Explicit commands/inputs, Ghostty commands, restore transactions,
    /// manual I/O, and managed shell integration retain ownership of their
    /// launch behavior. Suppressed surfaces use login mode so a declarative
    /// non-login preference cannot leak through.
    public func resolve(
        configuredMode: TerminalShellStartupMode,
        hasExplicitCommand: Bool,
        hasExplicitInput: Bool,
        hasGhosttyCommand: Bool,
        isRestoreSurface: Bool,
        isManualSurface: Bool,
        hasManagedShellIntegration: Bool = false
    ) -> Resolution {
        let allows = !hasExplicitCommand
            && !hasExplicitInput
            && !hasGhosttyCommand
            && !isRestoreSurface
            && !isManualSurface
            && !hasManagedShellIntegration
        return Resolution(
            allowsDeclarativeShellStartup: allows,
            mode: allows ? configuredMode : .login
        )
    }

    /// Returns a command override when the configured mode needs to replace
    /// Ghostty's default shell invocation.
    ///
    /// - Parameters:
    ///   - shell: Resolved user-shell executable path.
    ///   - configuration: Declarative shell-startup values.
    ///   - hasExplicitCommand: Whether the surface already supplies a launch command.
    ///   - hasExplicitInput: Whether the surface already supplies startup input.
    ///   - hasGhosttyCommand: Whether Ghostty config supplies a command.
    ///   - isRestoreSurface: Whether the surface belongs to a restore transaction.
    ///   - isManualSurface: Whether a caller manages the surface's I/O.
    ///   - hasManagedShellIntegration: Whether integration owns the launch command.
    /// - Returns: A safely quoted non-login command, or `nil` for native launch.
    public func commandOverride(
        shell: String?,
        configuration: TerminalShellStartupConfiguration,
        hasExplicitCommand: Bool,
        hasExplicitInput: Bool,
        hasGhosttyCommand: Bool,
        isRestoreSurface: Bool,
        isManualSurface: Bool,
        hasManagedShellIntegration: Bool = false
    ) -> String? {
        let resolution = resolve(
            configuredMode: configuration.mode,
            hasExplicitCommand: hasExplicitCommand,
            hasExplicitInput: hasExplicitInput,
            hasGhosttyCommand: hasGhosttyCommand,
            isRestoreSurface: isRestoreSurface,
            isManualSurface: isManualSurface,
            hasManagedShellIntegration: hasManagedShellIntegration
        )
        guard resolution.allowsDeclarativeShellStartup,
              resolution.mode == .nonLogin,
              let normalizedShell = shell?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedShell.isEmpty else {
            return nil
        }
        return nonLoginShellCommand(shell: normalizedShell, arguments: "-i")
    }

    /// Returns one-shot input sent after the ordinary shell starts.
    public func startupInput(
        configuration: TerminalShellStartupConfiguration,
        hasExplicitCommand: Bool,
        hasExplicitInput: Bool,
        hasGhosttyCommand: Bool,
        isRestoreSurface: Bool,
        isManualSurface: Bool,
        hasManagedShellIntegration: Bool = false
    ) -> String? {
        let resolution = resolve(
            configuredMode: configuration.mode,
            hasExplicitCommand: hasExplicitCommand,
            hasExplicitInput: hasExplicitInput,
            hasGhosttyCommand: hasGhosttyCommand,
            isRestoreSurface: isRestoreSurface,
            isManualSurface: isManualSurface,
            hasManagedShellIntegration: hasManagedShellIntegration
        )
        guard resolution.allowsDeclarativeShellStartup,
              let command = configuration.command else {
            return nil
        }
        return command + "\n"
    }

    /// Builds a Darwin-safe non-login command for Ghostty's login wrapper.
    func nonLoginShellCommand(shell: String, arguments: String) -> String {
        "/usr/bin/env \(TerminalSurface.shellSingleQuoted(shell)) \(arguments)"
    }
}
