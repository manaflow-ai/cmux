import Darwin

extension Workspace {
    var agentPIDNamespacesByKey: [String: AgentStatusPIDNamespace] {
        get { sidebarAgentRuntimeObservation.agentPIDNamespacesByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDNamespacesByKey(newValue) }
    }

    func isRecordedAgentPIDLive(key: String, pid: pid_t) -> Bool {
        guard pid > 0, agentPIDs[key] == pid else { return false }
        switch agentPIDNamespacesByKey[key] ?? .local {
        case .local:
            guard let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
                  let currentIdentity = Self.agentPIDProcessIdentity(pid: pid) else {
                return false
            }
            return currentIdentity == recordedIdentity
        case .remote:
            guard let panelId = agentPIDPanelIdsByKey[key],
                  agentPIDKeysByPanelId[panelId]?.contains(key) == true else {
                return false
            }
            return panels[panelId] != nil && isRemoteTerminalSurface(panelId)
        }
    }
}
