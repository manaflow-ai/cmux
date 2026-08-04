enum AgentHibernationLifecycleStatusKeys {
    /// Reserved namespace for `cmux workspace loading`: `manual` or
    /// `manual:<id>`. Excluded from `allowedStatusKeys` and from `isAllowed`
    /// (so `set_agent_lifecycle` rejects it): manual loaders enter only through
    /// the validated, capped `workspace_loading` path and drive the sidebar
    /// spinner, never hibernation/PID/status handling.
    static let manualKey = "manual"

    static func isManualKey(_ key: String) -> Bool {
        key == manualKey || key.hasPrefix("\(manualKey):")
    }

    static let allowedStatusKeys = Set(
        BuiltInAgentIntegration.allCases.map(\.statusKey)
    )

    static func isAllowed(_ key: String) -> Bool {
        allowedStatusKeys.contains(key)
    }
}
