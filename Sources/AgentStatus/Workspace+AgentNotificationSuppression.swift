import CmuxSettings
import Foundation

extension Workspace {
    private static let structuredAgentHookStatusKeys =
        AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    private static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    private static let truthyStartupEnvironmentValues: Set<String> =
        ["1", "true", "yes", "on", "enabled"]

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else { return false }

        if AgentIntegrationSettingsStore(defaults: .standard).suppressesSubagentNotifications,
           terminalPanelHasManagedSubagentStartupEnvironment(panelId: panelId) {
            return true
        }

        let resolutions = sidebarAgentRuntimeObservation.agentStatusLedger
            .resolutionsForPanel(panelId)
        return (agentPIDKeysByPanelId[panelId] ?? []).contains { key in
            guard isStructuredAgentHookPIDKey(key) else { return false }
            guard (agentPIDNamespacesByKey[key] ?? .local) == .remote else {
                return true
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard let resolution = resolutions[statusKey] else { return false }
            return resolution.lifecycle != .unknown
        }
    }

    private func terminalPanelHasManagedSubagentStartupEnvironment(panelId: UUID) -> Bool {
        guard let rawValue = terminalPanel(for: panelId)?
            .surface
            .startupEnvironmentValue(Self.managedSubagentEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return Self.truthyStartupEnvironmentValues.contains(rawValue)
    }

    func isStructuredAgentHookPIDKey(_ key: String) -> Bool {
        Self.structuredAgentHookStatusKeys.contains(agentStatusKey(forAgentPIDKey: key))
    }
}
