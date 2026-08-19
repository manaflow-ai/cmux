import CmuxSettings
import CmuxWorkspaces

extension CmuxSettingsFileStore {
    func parseAgentContextManagementSection(
        from section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let raw = section["agentContextManagement"] else { return }
        guard let contextManagement = raw as? [String: Any] else {
            logInvalid("terminal.agentContextManagement", sourcePath: sourcePath)
            return
        }

        let catalog = SettingCatalog().terminal
        if let value = jsonBool(contextManagement["enabled"]) {
            snapshot.managedUserDefaults[catalog.agentContextManagementEnabled.userDefaultsKey] = .bool(value)
        } else if contextManagement.keys.contains("enabled") {
            logInvalid("terminal.agentContextManagement.enabled", sourcePath: sourcePath)
        }
        if let rawAction = jsonString(contextManagement["action"]),
           AgentContextInjectionAction(rawValue: rawAction) != nil {
            snapshot.managedUserDefaults[catalog.agentContextManagementAction.userDefaultsKey] = .string(rawAction)
        } else if contextManagement.keys.contains("action") {
            logInvalid("terminal.agentContextManagement.action", sourcePath: sourcePath)
        }
        if let value = jsonBool(contextManagement["preserveState"]) {
            snapshot.managedUserDefaults[catalog.agentContextManagementPreserveState.userDefaultsKey] = .bool(value)
        } else if contextManagement.keys.contains("preserveState") {
            logInvalid("terminal.agentContextManagement.preserveState", sourcePath: sourcePath)
        }
    }
}
