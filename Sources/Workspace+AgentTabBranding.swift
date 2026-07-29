import Foundation

/// Attach-time snapshot for one panel's agent tab branding: which agent
/// attached and what the process title was at that moment.
struct AgentTabBrandingAttachState: Equatable {
    let definitionID: String
    let processTitleAtAttach: String?
}

/// Terminal-tab agent branding: while the hook-driven runtime maps that drive
/// the sidebar status pill report a coding agent attached to a panel, that
/// panel's tab shows the agent's brand icon (`Tab.iconAsset`) and an
/// agent-aware title resolved by `AgentTabBrandingResolver`.
extension Workspace {
    /// The coding-agent definition currently attached to `panelId`, resolved
    /// from hook-recorded PID ownership and lifecycle status keys — the same
    /// source of truth as the sidebar status pill, so the tab branding and the
    /// pill can never disagree about which agent a panel is running.
    func currentCodingAgentDefinition(panelId: UUID) -> CmuxTaskManagerCodingAgentDefinition? {
        var statusKeys = Set<String>()
        for key in agentPIDKeysByPanelId[panelId] ?? [] {
            statusKeys.insert(agentStatusKey(forAgentPIDKey: key))
        }
        for key in (agentLifecycleStatesByPanelId[panelId] ?? [:]).keys
        where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            statusKeys.insert(key)
        }
        guard !statusKeys.isEmpty else { return nil }
        return AgentTabBrandingResolver().definition(
            forStatusKeys: statusKeys,
            in: CmuxTaskManagerCodingAgentDefinition.builtIns
        )
    }

    /// Starts observing the agent runtime maps so tab branding follows agent
    /// attach/detach. Idempotent; the task is cancelled in `deinit`.
    func startAgentTabBrandingObservation() {
        guard agentTabBrandingObservationTask == nil else { return }
        let changes = sidebarAgentRuntimeObservation.changes()
        agentTabBrandingObservationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.refreshAgentTabBranding()
            }
        }
        refreshAgentTabBranding()
    }

    /// Re-applies agent branding for every terminal panel in the workspace.
    /// Cheap when nothing changed: `updateTab` diffs before mutating.
    func refreshAgentTabBranding() {
        guard !isRemoteTmuxMirror else { return }
        agentTabBrandingAttachState = agentTabBrandingAttachState.filter {
            panels[$0.key] != nil
        }
        for (panelId, panel) in panels where panel is TerminalPanel {
            refreshAgentTabBranding(panelId: panelId)
        }
    }

    /// Re-applies the brand icon and agent-aware title for one panel's tab,
    /// and reconciles the workspace title when the panel is focused.
    func refreshAgentTabBranding(panelId: UUID) {
        guard !isRemoteTmuxMirror,
              let panel = panels[panelId], panel is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else { return }
        let definition = currentCodingAgentDefinition(panelId: panelId)
        reconcileAgentTabBrandingAttachState(panelId: panelId, definition: definition)
        let iconAsset = definition?.assetName
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
        let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
        if titleUpdate != nil || existing.iconAsset != iconAsset {
            bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconAsset: .some(iconAsset)
            )
        }
        applyFocusedPanelTitle(panelId: panelId)
    }

    /// Records the process title in place when an agent attaches to a panel
    /// (or a different agent replaces it), and forgets it on detach. The
    /// snapshot is what lets the title rule distinguish "the CLI never set a
    /// title" from "the CLI took ownership of the title after launch".
    private func reconcileAgentTabBrandingAttachState(
        panelId: UUID,
        definition: CmuxTaskManagerCodingAgentDefinition?
    ) {
        guard let definition else {
            agentTabBrandingAttachState.removeValue(forKey: panelId)
            return
        }
        if agentTabBrandingAttachState[panelId]?.definitionID != definition.id {
            agentTabBrandingAttachState[panelId] = AgentTabBrandingAttachState(
                definitionID: definition.id,
                processTitleAtAttach: panelTitles[panelId]
            )
        }
    }
}
