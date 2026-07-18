import CmuxTerminalCore
import Foundation

extension AgentHibernationLifecycleStatusKeys {
    static func resolvedStates(
        _ panelStates: [String: AgentHibernationLifecycleState]
    ) -> [AgentHibernationLifecycleState] {
        var lifecycle = panelStates.filter {
            !isManualKey($0.key) && !isDetectionKey($0.key)
        }
        var screen: [AgentHibernationLifecycleState] = []
        for (key, state) in panelStates where isDetectionKey(key) {
            guard let familyID = detectionFamilyID(key: key),
                  let profile = AgentTerminalProfileCatalog.builtIn.profile(id: familyID) else {
                screen.append(state)
                continue
            }
            if profile.lifecycleAuthoritative {
                if lifecycle[profile.statusKey] == nil { screen.append(state) }
            } else {
                lifecycle.removeValue(forKey: profile.statusKey)
                screen.append(state)
            }
        }
        return Array(lifecycle.values) + screen
    }
}

extension Workspace {
    func setDetectedAgentLifecycle(
        statusKey: String?,
        familyID: String?,
        panelId: UUID,
        state: AgentTerminalSemanticState
    ) {
        guard panels[panelId] != nil else { return }
        let oldEffective = agentHibernationLifecycleState(panelId: panelId, fallback: nil)
        var states = agentLifecycleStatesByPanelId[panelId] ?? [:]
        states = states.filter { !AgentHibernationLifecycleStatusKeys.isDetectionKey($0.key) }
        if state != .unknown, let familyID, statusKey != nil {
            states[AgentHibernationLifecycleStatusKeys.detectionKey(familyID: familyID)] = state.hibernationLifecycleState
        }
        if states.isEmpty {
            agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
        } else {
            agentLifecycleStatesByPanelId[panelId] = states
        }
        let newEffective = agentHibernationLifecycleState(panelId: panelId, fallback: nil)
        if oldEffective != newEffective { recordDetectedAgentLifecycleChange(panelId: panelId) }
    }

    func clearDetectedAgentLifecycle(panelId: UUID) {
        setDetectedAgentLifecycle(statusKey: nil, familyID: nil, panelId: panelId, state: .unknown)
    }

    func observedAgentTerminalState(panelId: UUID) -> (family: String?, state: String, source: String) {
        let states = agentLifecycleStatesByPanelId[panelId] ?? [:]
        let lifecycle = states.filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) &&
            !AgentHibernationLifecycleStatusKeys.isDetectionKey($0.key)
        }
        if let detected = states.first(where: { AgentHibernationLifecycleStatusKeys.isDetectionKey($0.key) }) {
            let familyID = AgentHibernationLifecycleStatusKeys.detectionFamilyID(key: detected.key)
            let profile = familyID.flatMap { AgentTerminalProfileCatalog.builtIn.profile(id: $0) }
            if profile?.lifecycleAuthoritative != true || lifecycle[profile?.statusKey ?? ""] == nil {
                return (familyID, detected.value.semanticState.rawValue, "screen")
            }
        }
        if !lifecycle.isEmpty {
            return (lifecycle.keys.sorted().first, AgentHibernationLifecycleState.effective(lifecycle.values).rawValue, "lifecycle")
        }
        return (nil, AgentTerminalSemanticState.unknown.rawValue, "none")
    }

    private func recordDetectedAgentLifecycleChange(panelId: UUID) {
        recordAgentHibernationLifecycleChange(panelId: panelId)
    }
}

private extension AgentTerminalSemanticState {
    var hibernationLifecycleState: AgentHibernationLifecycleState {
        switch self {
        case .unknown: .unknown
        case .idle: .idle
        case .working: .running
        case .blocked: .needsInput
        }
    }
}

private extension AgentHibernationLifecycleState {
    var semanticState: AgentTerminalSemanticState {
        switch self {
        case .unknown: .unknown
        case .idle: .idle
        case .running: .working
        case .needsInput: .blocked
        }
    }
}
