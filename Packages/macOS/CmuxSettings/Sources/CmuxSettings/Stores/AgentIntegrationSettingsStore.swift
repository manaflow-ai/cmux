import Foundation

/// Repository for the agent-integration settings, persisted in
/// `UserDefaults` under the catalog's `integrations.*` keys. Folds the
/// per-agent hook toggles (Claude Code, Cursor, Gemini, Kiro, Amp), the
/// custom `claude` path, the Kiro notification level, and subagent
/// notification suppression into one domain store.
///
/// Isolation: a stateless `Sendable` struct, not an actor — every reader is
/// synchronous terminal-environment setup code, the struct holds no mutable
/// state, and `UserDefaults` is documented thread-safe.
public struct AgentIntegrationSettingsStore: AgentIntegrationSettingsReading {
    /// Environment variable carrying ``suppressesSubagentNotifications`` to
    /// spawned terminal processes (`"1"` suppressed / `"0"` not). The name is
    /// wire format shared with the `cmux` CLI.
    public static let subagentSuppressionEnvironmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = IntegrationsCatalogSection()

    /// Creates a store reading the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var claudeCodeHooksEnabled: Bool {
        keys.claudeCodeHooksEnabled.value(in: defaults)
    }

    public var customClaudePath: String? {
        let value = keys.claudeCodeCustomClaudePath.value(in: defaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public var cursorHooksEnabled: Bool {
        keys.cursorHooksEnabled.value(in: defaults)
    }

    public var geminiHooksEnabled: Bool {
        keys.geminiHooksEnabled.value(in: defaults)
    }

    public var kiroHooksEnabled: Bool {
        keys.kiroHooksEnabled.value(in: defaults)
    }

    public var kiroNotificationLevel: KiroNotificationLevel {
        KiroNotificationLevel(rawValue: keys.kiroNotificationLevel.value(in: defaults)) ?? .standard
    }

    public var ampHooksEnabled: Bool {
        keys.ampHooksEnabled.value(in: defaults)
    }

    public var suppressesSubagentNotifications: Bool {
        keys.suppressSubagentNotifications.value(in: defaults)
    }
}
