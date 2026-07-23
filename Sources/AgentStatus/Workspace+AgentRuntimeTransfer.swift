import CmuxSidebar
import Darwin
import Foundation

extension Workspace {
    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []
        var panelPIDs: [String: pid_t] = [:]
        var panelIdentities: [String: AgentPIDProcessIdentity] = [:]
        var panelNamespaces: [String: AgentStatusPIDNamespace] = [:]
        var panelStatuses: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                panelPIDs[key] = pid
                panelIdentities[key] = agentPIDProcessIdentitiesByKey[key]
                panelNamespaces[key] = agentPIDNamespacesByKey[key] ?? .local
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            panelStatuses[statusKey] = statusEntries[statusKey]
        }
        guard !panelStatuses.isEmpty || !panelPIDs.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: panelStatuses,
            agentPIDs: panelPIDs,
            agentPIDProcessIdentities: panelIdentities,
            agentPIDKeys: pidKeys,
            agentPIDNamespaces: panelNamespaces,
            agentStatusEvidence: sidebarAgentRuntimeObservation.agentStatusLedger.evidenceForPanel(panelId),
            agentStatusResolutions: sidebarAgentRuntimeObservation.agentStatusLedger.resolutionsForPanel(panelId)
        )
    }

    @discardableResult
    func discardAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(
                key: key,
                panelId: runtimeState.panelId,
                clearStatus: true,
                refreshPorts: false
            ) {
                didChange = true
            }
        }
        if didChange { refreshTrackedAgentPorts() }
        return didChange
    }

    func adoptDetachedAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        sidebarAgentRuntimeObservation.agentStatusLedger.adopt(
            evidence: runtimeState.agentStatusEvidence,
            resolutions: runtimeState.agentStatusResolutions,
            panelId: runtimeState.panelId
        )
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs {
            recordAgentPID(
                key: key,
                pid: pid,
                panelId: runtimeState.panelId,
                pidNamespace: runtimeState.agentPIDNamespaces[key] ?? .local,
                refreshPorts: false
            )
            if let recordedIdentity = runtimeState.agentPIDProcessIdentities[key] {
                agentPIDProcessIdentitiesByKey[key] = recordedIdentity
            }
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        reconcileAgentStatuses(panelId: runtimeState.panelId)
        if didAdoptAgentPID { refreshTrackedAgentPorts() }
    }
}
