/// Retry preferences are interpreted by acpmux. The app validates and presents them only.
public nonisolated struct AgentRetrySettings: Sendable, Equatable {
    public var enabled = AgentRetrySettings.retryEnabledDefault
    public var intervalSeconds = AgentRetrySettings.retryIntervalSecondsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "retry"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("intervalSeconds", range: retryIntervalSecondsRange) { settings.intervalSeconds = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
