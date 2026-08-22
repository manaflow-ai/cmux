import Foundation

/// Shell invocation mode understood by the terminal spawn layer.
public enum TerminalShellStartupMode: String, CaseIterable, Sendable {
    /// Start an interactive login shell.
    case login
    /// Start an interactive non-login shell.
    case nonLogin
}

/// The declarative startup behavior for an ordinary local terminal surface.
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

/// Pure launch decisions for the declarative shell-startup settings.
public struct TerminalShellStartupPolicy: Sendable {
    /// The resolved mode and eligibility for applying declarative startup
    /// defaults to one newly-created surface.
    public struct Resolution: Equatable, Sendable {
        /// Whether the declarative shell mode and startup command may apply.
        public let allowsDeclarativeShellStartup: Bool
        /// Effective mode, falling back to login when another startup owner
        /// already controls the surface.
        public let mode: TerminalShellStartupMode

        /// Creates a resolved startup decision.
        public init(
            allowsDeclarativeShellStartup: Bool,
            mode: TerminalShellStartupMode
        ) {
            self.allowsDeclarativeShellStartup = allowsDeclarativeShellStartup
            self.mode = mode
        }
    }

    /// Creates a shell-startup decision policy.
    public init() {}

    /// Resolves whether declarative shell startup owns a surface.
    ///
    /// The decision is deliberately pure and shared by runtime surface
    /// creation and unit tests. Explicit commands/inputs, Ghostty commands,
    /// restore transactions, manual I/O, and managed shell integration all
    /// retain ownership of their launch behavior. Suppressed surfaces use
    /// login mode so a declarative non-login preference cannot leak through.
    public static func resolve(
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
    /// Ghostty's default shell invocation. Login mode intentionally returns
    /// `nil` so Ghostty retains its native shell resolution and integration
    /// behavior.
    ///
    /// - Parameters:
    ///   - shell: Resolved user-shell executable path.
    ///   - configuration: Declarative shell-startup values.
    ///   - hasExplicitCommand: Whether the surface already supplies a launch
    ///     command.
    ///   - hasExplicitInput: Whether the surface already supplies startup
    ///     input.
    ///   - hasGhosttyCommand: Whether Ghostty config supplies a command.
    ///   - isRestoreSurface: Whether the surface belongs to a restore
    ///     transaction.
    ///   - isManualSurface: Whether a caller manages the surface's I/O.
    ///   - hasManagedShellIntegration: Whether cmux shell integration already
    ///     owns the launch command.
    /// - Returns: A safely quoted non-login command, or `nil` when the native
    ///   Ghostty launch must remain unchanged.
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
        let resolution = Self.resolve(
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
        return Self.nonLoginShellCommand(shell: normalizedShell, arguments: "-i")
    }

    /// Returns the one-shot input sent after the ordinary shell starts.
    /// Explicit commands/inputs and restored/manual surfaces are never
    /// modified by the declarative default.
    ///
    /// - Parameters:
    ///   - configuration: Declarative shell-startup values.
    ///   - hasExplicitCommand: Whether the surface already supplies a launch
    ///     command.
    ///   - hasExplicitInput: Whether the surface already supplies startup
    ///     input.
    ///   - hasGhosttyCommand: Whether Ghostty config supplies a command.
    ///   - isRestoreSurface: Whether the surface belongs to a restore
    ///     transaction.
    ///   - isManualSurface: Whether a caller manages the surface's I/O.
    /// - Returns: Newline-terminated one-shot startup input, or `nil` when no
    ///   declarative input should be applied.
    public func startupInput(
        configuration: TerminalShellStartupConfiguration,
        hasExplicitCommand: Bool,
        hasExplicitInput: Bool,
        hasGhosttyCommand: Bool,
        isRestoreSurface: Bool,
        isManualSurface: Bool,
        hasManagedShellIntegration: Bool = false
    ) -> String? {
        let resolution = Self.resolve(
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
    /// Ghostty wraps shell commands in `/usr/bin/login ... exec -l`, even
    /// when the command text asks the shell for `-i`. Put an absolute `env`
    /// hop in front of the requested executable so the login flag lands on
    /// `env`'s argv0; `env` then execs the user's shell with its normal argv0,
    /// which retains a non-login shell on Darwin while still letting Ghostty
    /// establish the terminal environment.
    static func nonLoginShellCommand(shell: String, arguments: String) -> String {
        "/usr/bin/env \(TerminalSurface.shellSingleQuoted(shell)) \(arguments)"
    }
}
