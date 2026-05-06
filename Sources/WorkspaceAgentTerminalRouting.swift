import Foundation

extension Workspace {
    func markAgentTerminal(panelId: UUID, key: String) {
        guard panels[panelId]?.panelType == .terminal else { return }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        agentStatusKeysByPanelId[panelId, default: []].insert(trimmedKey)
    }

    func clearAgentTerminal(key: String, panelId: UUID? = nil) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        if let panelId {
            guard var keys = agentStatusKeysByPanelId[panelId] else { return }
            keys.remove(trimmedKey)
            if keys.isEmpty {
                agentStatusKeysByPanelId.removeValue(forKey: panelId)
            } else {
                agentStatusKeysByPanelId[panelId] = keys
            }
            return
        }

        for existingPanelId in Array(agentStatusKeysByPanelId.keys) {
            clearAgentTerminal(key: trimmedKey, panelId: existingPanelId)
        }
    }

    func setAgentPID(key: String, pid: pid_t, panelId: UUID? = nil) {
        agentPIDs[key] = pid
        if let panelId {
            markAgentTerminal(panelId: panelId, key: key)
        }
    }

    @discardableResult
    func clearAgentPID(key: String, panelId: UUID? = nil) -> pid_t? {
        clearAgentTerminal(key: key, panelId: panelId)
        return agentPIDs.removeValue(forKey: key)
    }

    func terminalPanelHostsAgent(panelId: UUID) -> Bool {
        guard panels[panelId]?.panelType == .terminal else { return false }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            return true
        }
        return agentStatusKeysByPanelId[panelId]?.isEmpty == false
    }

    func externalFileDropRouting(forPanelId panelId: UUID) -> PaneExternalFileDropRouting {
        guard let panelType = panels[panelId]?.panelType else {
            return .filePreview
        }
        return PaneDropRouting.externalFileDropRouting(
            panelType: panelType,
            hostsAgent: terminalPanelHostsAgent(panelId: panelId)
        )
    }
}
