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
            guard var keys = agentStatusKeysByPanelId[panelId] else {
                clearRestoredAgentSnapshotForAgentRouting(panelId: panelId, matchingKey: trimmedKey)
                return
            }
            keys.remove(trimmedKey)
            if keys.isEmpty {
                agentStatusKeysByPanelId.removeValue(forKey: panelId)
                clearRestoredAgentSnapshotForAgentRouting(panelId: panelId, matchingKey: trimmedKey)
            } else {
                agentStatusKeysByPanelId[panelId] = keys
            }
            return
        }

        for existingPanelId in Array(agentStatusKeysByPanelId.keys) {
            clearAgentTerminal(key: trimmedKey, panelId: existingPanelId)
        }
        for (existingPanelId, snapshot) in Array(restoredAgentSnapshotsByPanelId)
            where restoredAgentSnapshot(snapshot, matchesStatusKey: trimmedKey)
        {
            clearRestoredAgentSnapshotForAgentRouting(panelId: existingPanelId)
        }
    }

    private func clearRestoredAgentSnapshotForAgentRouting(panelId: UUID, matchingKey key: String) {
        guard let snapshot = restoredAgentSnapshotsByPanelId[panelId],
              restoredAgentSnapshot(snapshot, matchesStatusKey: key) else {
            return
        }
        clearRestoredAgentSnapshotForAgentRouting(panelId: panelId)
    }

    func setAgentPID(key: String, pid: pid_t, panelId: UUID? = nil) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        agentPIDs[trimmedKey] = pid
        if let panelId {
            markAgentTerminal(panelId: panelId, key: trimmedKey)
        }
    }

    @discardableResult
    func clearAgentPID(key: String, panelId: UUID? = nil) -> pid_t? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        clearAgentTerminal(key: trimmedKey, panelId: panelId)
        return agentPIDs.removeValue(forKey: trimmedKey)
    }

    func terminalPanelHostsAgent(panelId: UUID) -> Bool {
        guard panels[panelId]?.panelType == .terminal else { return false }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            return true
        }
        return agentStatusKeysByPanelId[panelId]?.isEmpty == false
    }

    func externalFileDropRouting(
        forPanelId panelId: UUID,
        shiftKeyHeld: Bool = false,
        defaults: UserDefaults = .standard
    ) -> PaneExternalFileDropRouting {
        guard let panelType = panels[panelId]?.panelType else {
            return .filePreview
        }
        return PaneDropRouting.externalFileDropRouting(
            panelType: panelType,
            hostsAgent: terminalPanelHostsAgent(panelId: panelId),
            defaultAction: TerminalFileDropSettings.defaultAction(defaults: defaults),
            shiftKeyHeld: shiftKeyHeld
        )
    }

    func externalFileDropHint(
        forPanelId panelId: UUID,
        shiftKeyHeld: Bool = false,
        defaults: UserDefaults = .standard
    ) -> PaneFileDropHint? {
        guard let panelType = panels[panelId]?.panelType else {
            return nil
        }
        return PaneDropRouting.externalFileDropHint(
            panelType: panelType,
            hostsAgent: terminalPanelHostsAgent(panelId: panelId),
            defaultAction: TerminalFileDropSettings.defaultAction(defaults: defaults),
            shiftKeyHeld: shiftKeyHeld
        )
    }

    private func restoredAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot,
        matchesStatusKey key: String
    ) -> Bool {
        let baseKey = key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? key
        switch snapshot.kind {
        case .claude:
            return baseKey == "claude" || baseKey == "claude_code"
        case .codex:
            return baseKey == "codex"
        case .pi:
            return baseKey == "pi"
        case .cursor:
            return baseKey == "cursor"
        case .gemini:
            return baseKey == "gemini"
        case .opencode:
            return baseKey == "opencode"
        case .rovodev:
            return baseKey == "rovodev"
        case .hermesAgent:
            return baseKey == "hermes-agent" || baseKey == "hermes"
        case .copilot:
            return baseKey == "copilot"
        case .codebuddy:
            return baseKey == "codebuddy"
        case .factory:
            return baseKey == "factory"
        case .qoder:
            return baseKey == "qoder"
        }
    }
}
