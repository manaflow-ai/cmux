import Darwin

extension Workspace {
    var agentPIDNamespacesByKey: [String: AgentStatusPIDNamespace] {
        get { sidebarAgentRuntimeObservation.agentPIDNamespacesByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDNamespacesByKey(newValue) }
    }

    func recordedAgentRuntimeLiveness(
        key: String,
        pid: pid_t
    ) -> AgentStatusRuntimeLiveness {
        guard pid > 0, agentPIDs[key] == pid else { return .absent }
        switch agentPIDNamespacesByKey[key] ?? .local {
        case .local:
            guard let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
                  let currentIdentity = Self.agentPIDProcessIdentity(pid: pid) else {
                return .absent
            }
            return currentIdentity == recordedIdentity ? .confirmed : .absent
        case .remote:
            guard let panelId = agentPIDPanelIdsByKey[key],
                  agentPIDKeysByPanelId[panelId]?.contains(key) == true else {
                return .absent
            }
            return panels[panelId] != nil && isRemoteTerminalSurface(panelId)
                ? .unverifiable
                : .absent
        }
    }

    func shouldRetainRecordedAgentPID(key: String, pid: pid_t) -> Bool {
        recordedAgentRuntimeLiveness(key: key, pid: pid) != .absent
    }
}
