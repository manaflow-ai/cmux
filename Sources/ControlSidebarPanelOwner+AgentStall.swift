import CMUXAgentLaunch
import Darwin
import Foundation

@MainActor
extension ControlSidebarPanelOwner {
    var agentStallOwnerToken: String {
        switch self {
        case .workspace(let workspace):
            // Include the in-process owner identity as well as the workspace
            // UUID. A pane can move between a workspace and a same-UUID Dock;
            // UUID-only tokens would let a stale retry survive that transfer.
            "workspace:\(workspace.id.uuidString.lowercased()):\(ObjectIdentifier(workspace))"
        case .dock(let dock):
            "dock:\(dock.workspaceId.uuidString.lowercased()):\(ObjectIdentifier(dock))"
        }
    }

    var agentStallTitle: String {
        let value = switch self {
        case .workspace(let workspace): workspace.title
        case .dock(let dock): dock.sourceLabel
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "agent.stall.workspace.untitled", defaultValue: "Workspace")
        }
        return trimmed
    }

    func containsAgentStallPanel(_ panelID: UUID) -> Bool {
        switch self {
        case .workspace(let workspace): workspace.panels[panelID] is TerminalPanel
        case .dock(let dock): dock.panels[panelID] is TerminalPanel
        }
    }

    func agentStallPanel(_ panelID: UUID) -> TerminalPanel? {
        switch self {
        case .workspace(let workspace): workspace.panels[panelID] as? TerminalPanel
        case .dock(let dock): dock.panels[panelID] as? TerminalPanel
        }
    }

    func agentStallResumeBinding(_ panelID: UUID) -> SurfaceResumeBindingSnapshot? {
        switch self {
        case .workspace(let workspace):
            workspace.surfaceResumeBinding(panelId: panelID)
        case .dock(let dock):
            dock.managedAgentResumeBinding(panelId: panelID)
                ?? dock.surfaceResumeBinding(panelId: panelID)
        }
    }

    func agentStallLifecycle(
        key: String,
        panelID: UUID
    ) -> AgentHibernationLifecycleState {
        switch self {
        case .workspace(let workspace):
            workspace.agentLifecycleStatesByPanelId[panelID]?[key] ?? .unknown
        case .dock(let dock):
            dock.agentRuntimeByPanelId[panelID]?.agentLifecycleStates[key] ?? .unknown
        }
    }

    /// Captures only a live process generation owned by this provider session.
    func agentStallProcessIdentity(
        provider: String,
        checkpointID: String,
        panelID: UUID
    ) -> (pid: pid_t, identity: AgentPIDProcessIdentity)? {
        let expectedKeys = agentStallProcessKeys(provider: provider, checkpointID: checkpointID)
        let candidate: (pid_t, AgentPIDProcessIdentity)?
        switch self {
        case .workspace(let workspace):
            candidate = expectedKeys.lazy.compactMap { key in
                guard workspace.agentPIDKeysByPanelId[panelID]?.contains(key) == true,
                      let pid = workspace.agentPIDs[key],
                      let identity = workspace.agentPIDProcessIdentitiesByKey[key] else {
                    return nil
                }
                return (pid, identity)
            }.first
        case .dock(let dock):
            guard let runtime = dock.agentRuntimeByPanelId[panelID] else { return nil }
            candidate = expectedKeys.lazy.compactMap { key in
                guard runtime.agentPIDKeys.contains(key),
                      let pid = runtime.agentPIDs[key],
                      let identity = runtime.agentPIDProcessIdentities[key] else {
                    return nil
                }
                return (pid, identity)
            }.first
        }
        guard let candidate,
              candidate.0 > 0,
              PIDPresence.current(pid: candidate.0) == .present,
              candidate.1.pid == candidate.0,
              Workspace.agentPIDProcessIdentity(pid: candidate.0) == candidate.1 else {
            return nil
        }
        return candidate
    }

    /// Revalidates both the stored owner mapping and the live process birth time.
    func agentStallMatchesProcessGeneration(
        provider: String,
        checkpointID: String,
        panelID: UUID,
        recordedPID: pid_t,
        recordedIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard recordedPID > 0,
              PIDPresence.current(pid: recordedPID) == .present,
              recordedIdentity.pid == recordedPID,
              Workspace.agentPIDProcessIdentity(pid: recordedPID) == recordedIdentity else {
            return false
        }
        let expectedKeys = Set(agentStallProcessKeys(
            provider: provider,
            checkpointID: checkpointID
        ))
        switch self {
        case .workspace(let workspace):
            return (workspace.agentPIDKeysByPanelId[panelID] ?? []).contains { key in
                expectedKeys.contains(key)
                    && workspace.agentPIDs[key] == recordedPID
                    && workspace.agentPIDProcessIdentitiesByKey[key] == recordedIdentity
            }
        case .dock(let dock):
            guard let runtime = dock.agentRuntimeByPanelId[panelID] else { return false }
            return runtime.agentPIDKeys.contains { key in
                expectedKeys.contains(key)
                    && runtime.agentPIDs[key] == recordedPID
                    && runtime.agentPIDProcessIdentities[key] == recordedIdentity
            }
        }
    }

    func agentStallProcessLiveness(
        provider: String,
        checkpointID: String,
        panelID: UUID,
        recordedPID: pid_t?,
        recordedIdentity: AgentPIDProcessIdentity?
    ) -> AgentStallProcessLiveness {
        guard let recordedPID, let recordedIdentity else { return .unknown }
        if agentStallMatchesProcessGeneration(
            provider: provider,
            checkpointID: checkpointID,
            panelID: panelID,
            recordedPID: recordedPID,
            recordedIdentity: recordedIdentity
        ) {
            return .running
        }
        switch PIDPresence.current(pid: recordedPID) {
        case .absent:
            return .exited
        case .present, .unknown:
            // A present PID with a different birth time is a reused process,
            // not proof that the captured managed generation is still alive.
            return .unknown
        }
    }

    private func agentStallProcessKeys(
        provider: String,
        checkpointID: String
    ) -> [String] {
        let providerKey = provider == "claude" ? "claude_code" : provider
        return ["\(providerKey).\(checkpointID)", providerKey]
    }
}
