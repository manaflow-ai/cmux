import Foundation

/// The launch command and prompt-reporting capability installed together for a shell.
public struct TerminalManagedShellStartupPlan: Sendable {
    /// Replacement command, or nil when the shell uses environment-based integration.
    public let command: String?
    /// Whether this plan installed integration that can report prompt readiness.
    public let reportsPromptReadiness: Bool

    /// Creates a shell plan from its installed integration.
    /// - Parameters:
    ///   - command: The replacement launch command, if needed.
    ///   - reportsPromptReadiness: Whether the installed payload reports prompts.
    public init(command: String?, reportsPromptReadiness: Bool) {
        self.command = command
        self.reportsPromptReadiness = reportsPromptReadiness
    }
}
