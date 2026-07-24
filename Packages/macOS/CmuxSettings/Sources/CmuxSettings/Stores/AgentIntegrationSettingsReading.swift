import Foundation

/// Read access to the agent-integration settings (Claude Code, Cursor,
/// Gemini, Kiro, Amp hooks and subagent notification suppression).
///
/// Consumer domains (terminal environment setup, agent launch) depend on
/// this seam instead of the concrete ``AgentIntegrationSettingsStore``.
public protocol AgentIntegrationSettingsReading: Sendable {
    /// Whether the Claude Code hooks integration is enabled.
    var claudeCodeHooksEnabled: Bool { get }

    /// Whether the Codex hooks integration (the `codex` wrapper) is enabled.
    var codexHooksEnabled: Bool { get }

    /// The user-configured `claude` executable path, or `nil` to resolve
    /// `claude` from `PATH`. Whitespace-only values read as `nil`.
    var customClaudePath: String? { get }

    /// Whether the Cursor hooks integration is enabled.
    var cursorHooksEnabled: Bool { get }

    /// Whether the Gemini hooks integration is enabled.
    var geminiHooksEnabled: Bool { get }

    /// Whether the Kiro hooks integration is enabled.
    var kiroHooksEnabled: Bool { get }

    /// The Kiro notification verbosity; unrecognized stored values read as
    /// ``KiroNotificationLevel/standard``.
    var kiroNotificationLevel: KiroNotificationLevel { get }

    /// Whether the Amp hooks integration is enabled.
    var ampHooksEnabled: Bool { get }

    /// Whether notifications from agent subagents are suppressed.
    var suppressesSubagentNotifications: Bool { get }
}
