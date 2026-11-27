// The paths, defaults and ranges are generated from schemas/settings/source/agent-retry.json
// (Schema/SettingsSchema+AgentRetry.generated.swift); this file only parses.

/// `agents.autoRetry.*` in cmux.json: whether a chat's turn that a rate limit, a capacity error or
/// a lost connection ended is sent again by itself, how long each wait is and how many tries run.
/// The acpmux daemon reads the same file at each retry and runs the loop; the app shows and
/// validates the keys.
public nonisolated struct AgentRetrySettings: Sendable, Equatable {
    public var enabled = AgentRetrySettings.autoRetryEnabledDefault
    public var intervalSeconds = AgentRetrySettings.autoRetryIntervalDefault
    public var attempts = AgentRetrySettings.autoRetryAttemptsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "autoRetry"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("intervalSeconds", range: autoRetryIntervalRange) { settings.intervalSeconds = value }
        if let value = reader.number("attempts", range: autoRetryAttemptsRange) { settings.attempts = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
