import CMUXAgentLaunch

/// The account environment a Claude account switch hands `respawnTerminalSurface`.
///
/// The plan names a value for each account key, where an empty value means "unset". An empty
/// value is sent only when the key would otherwise reach the new shell from the workspace's
/// environment or the app's own process environment, because only an override can mask those.
/// Every other unset key is removed from the env the old surface carried, so the default
/// account runs with no `CLAUDE_CONFIG_DIR` at all (#4255).
struct ClaudeAccountSwitchSurfaceEnvironment: Equatable {
    /// Values for `environmentOverrides`; `""` masks an inherited key.
    let overrides: [String: String]
    /// Keys for `removingEnvironmentKeys`; nothing else supplies them.
    let removedKeys: Set<String>

    init(
        plan: ClaudeAccountSwitchPlan,
        workspaceEnvironment: [String: String],
        processEnvironment: [String: String]
    ) {
        var overrides: [String: String] = [:]
        var removedKeys: Set<String> = []
        for (key, value) in plan.surfaceEnvironmentOverrides {
            if !value.isEmpty {
                overrides[key] = value
            } else if workspaceEnvironment[key]?.isEmpty == false || processEnvironment[key]?.isEmpty == false {
                overrides[key] = ""
            } else {
                removedKeys.insert(key)
            }
        }
        self.overrides = overrides
        self.removedKeys = removedKeys
    }
}
