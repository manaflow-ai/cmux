import CmuxSettings

/// Maps `agentActions` JSON keys to their catalog-backed defaults entries.
struct AgentActionsSettingsFileMapping {
    let booleanSettings: [SettingsFileBooleanMapping]

    init(agentActions: AgentActionsCatalogSection = AgentActionsCatalogSection()) {
        booleanSettings = [
            .init(
                jsonKey: "turnControl",
                defaultsKey: agentActions.turnControl.userDefaultsKey,
                invalidPath: agentActions.turnControl.id
            ),
        ]
    }
}
