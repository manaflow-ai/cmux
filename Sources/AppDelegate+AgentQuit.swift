import Foundation

extension AppDelegate {
    /// The fresh index decides which agents to signal; this cheap gate only
    /// decides whether quit needs asynchronous snapshot/cleanup at all.
    var hasLocalTerminalsForAgentQuit: Bool {
        let managers = mainWindowContexts.values.map(\.tabManager) + [tabManager].compactMap { $0 }
        return managers.contains { manager in
            manager.tabs.contains { workspace in
                !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror
                    && workspace.panels.values.contains { $0 is TerminalPanel }
            }
        }
    }

    /// Called only after persisting the pre-signal session snapshot.
    func terminateOwnedCodexProcessesForQuit(index: RestorableAgentSessionIndex) async {
        // Codex owns the writer resource addressed here. Other agents retain
        // their existing quit contract (Claude has separate transcript guards).
        let records = agentHibernationRecords(
            index: index, activityByPanel: [:], terminalInputByPanel: [:], lifecycleChangeByPanel: [:]
        ).filter {
            $0.agent.kind.rawValue == "codex" && $0.hasPressureSafeProcessEvidence
                && !$0.workspace.isRemoteWorkspace && !$0.workspace.isRemoteTmuxMirror
        }
        let recordsByKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        await AgentQuitProcessCleanup().terminate(scopes: records.map(\.processTerminationScope)) { [weak self] key in
            guard let self, self.isTerminatingApp, let record = recordsByKey[key] else { return false }
            return record.workspace.panels[key.panelId] === record.terminalPanel
                && record.terminalPanel.workspaceId == key.workspaceId
                && !record.workspace.isRemoteWorkspace && !record.workspace.isRemoteTmuxMirror
        }
    }
}
