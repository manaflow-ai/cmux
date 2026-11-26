import Foundation

/// Decides whether a spawned terminal will report prompt readiness through cmux shell integration.
///
/// Admission-held startup input waits for that report. When no report can arrive
/// (integration disabled, unsupported shell, or a custom command), the input must
/// be delivered directly at spawn instead of waiting forever.
public struct TerminalShellPromptReadinessPolicy: Sendable {
    /// Creates a stateless readiness policy.
    public init() {}

    /// - Parameters:
    ///   - integrationDirectory: The bundled integration directory, or nil when integration was not applied.
    ///   - resolvedCommand: The per-surface command override; nil means the managed user shell launches.
    ///   - hasUserGhosttyCommand: Whether Ghostty's own config replaces the user shell.
    ///   - resolvedShell: The user shell cmux resolved for this surface.
    ///   - managedShellCommand: cmux's shell-integration wrapper command, when the shell needs one.
    ///   - environment: The final startup environment passed to the shell.
    ///   - managedShellReportsPromptReadiness: Whether the actual managed payload installs prompt hooks.
    /// - Returns: True only when the launched process is a shell whose cmux integration was installed.
    public func reportsPromptReadiness(
        integrationDirectory: String?,
        resolvedCommand: String?,
        hasUserGhosttyCommand: Bool,
        resolvedShell: String?,
        managedShellCommand: String?,
        environment: [String: String],
        managedShellReportsPromptReadiness: Bool = false
    ) -> Bool {
        guard managedShellReportsPromptReadiness,
              let integrationDirectory, let resolvedShell, !hasUserGhosttyCommand else { return false }
        if let resolvedCommand, !resolvedCommand.isEmpty,
           resolvedCommand != managedShellCommand, resolvedCommand != resolvedShell {
            return false
        }
        switch URL(fileURLWithPath: resolvedShell).lastPathComponent {
        case "zsh":
            return environment["ZDOTDIR"] == integrationDirectory
        case "bash":
            return environment["PROMPT_COMMAND"]?.isEmpty == false
        case "fish", "nu":
            return managedShellCommand != nil && resolvedCommand == managedShellCommand
        default:
            return false
        }
    }
}
