import CMUXAgentLaunch
import Foundation

@MainActor
extension AgentStallSupervisor {
    func resolveOwner(
        panelID: UUID,
        preferredWorkspaceID: UUID?
    ) -> ControlSidebarPanelOwner? {
        if let dock = DockSplitStore.liveStore(containingPanel: panelID) {
            return .dock(dock)
        }
        return app?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: preferredWorkspaceID
        ).map { .workspace($0.workspace) }
    }

    func supportedProvider(kind: String?, key: String) -> String? {
        guard let kind else { return nil }
        let bindingProvider = AgentStallClassifier.canonicalProvider(kind)
        // `set_agent_pid` keys are namespaced as `<provider>.<session>` while
        // lifecycle keys are the bare provider status key. Compare the stable
        // provider prefix so PID reports can refresh the same managed run.
        let lifecycleKeyProvider = key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? key
        let lifecycleProvider = AgentStallClassifier.canonicalProvider(lifecycleKeyProvider)
        guard bindingProvider == lifecycleProvider,
              bindingProvider == "claude" || bindingProvider == "codex" else {
            return nil
        }
        return bindingProvider
    }

    func clearStatusEverywhere(panelID: UUID) {
        let key = AgentStallPresentation.statusKey(panelID)
        for workspace in app?.openWorkspacesForPetCensus() ?? [] {
            workspace.statusEntries.removeValue(forKey: key)
        }
        for dock in DockSplitStore.liveStores {
            dock.clearAgentRuntimeStatusEntry(key: key, panelId: panelID)
        }
    }
}
