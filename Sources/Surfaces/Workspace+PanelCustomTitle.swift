import Foundation

/// Shared tab-title action for UI, socket, agent hooks, restore and daemon reconciliation.
extension Workspace {
    @discardableResult
    func setPanelCustomTitle(
        panelId: UUID,
        title: String?,
        source: CustomTitleSource = .user,
        propagateToRemoteTmux: Bool = true,
        propagateToCloud: Bool = true,
        catalog: SurfaceCatalog = .shared
    ) -> Bool {
        guard panels[panelId] != nil else { return false }
        let previousWorkspaceTitle = self.title
        defer {
            if self.title != previousWorkspaceTitle {
                owningTabManager?.panelCustomTitleDidReconcileWorkspaceTitle(self)
            }
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        let previousSource = panelCustomTitleSources[panelId]
        let cloudResourceForPropagation = propagateToCloud && source != .remote
            ? cloudProjectedResource(forPanel: panelId, catalog: catalog) : nil
        if let resource = cloudResourceForPropagation, resource.kind == .terminal {
            guard catalog.cloudWorkspaceRenameService.admitsTerminalRename(workspace: self,
                panelID: panelId, resource: resource, source: source, catalog: catalog) else { return false }
        }
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if previous != nil, (previousSource ?? .user) != .auto { return false }
        }
        var sameText = false
        if trimmed.isEmpty {
            let canClearRemoteName = cloudResourceForPropagation?.kind == .terminal
            guard previous != nil || canClearRemoteName else { return false }
            if previous != nil {
                panelCustomTitles.removeValue(forKey: panelId)
                panelCustomTitleSources.removeValue(forKey: panelId)
            }
        } else {
            if previous == trimmed {
                // Same text still updates provenance. A remote observation must
                // be able to turn a just-confirmed local intent into settled
                // daemon-owned state without changing the visible tab twice.
                panelCustomTitleSources[panelId] = source
                sameText = true
            } else {
                panelCustomTitles[panelId] = trimmed
                panelCustomTitleSources[panelId] = source
            }
        }

        applyFocusedPanelTitle(panelId: panelId)

        // A repeated remote observation only changes provenance.
        // A repeated user or agent edit remains an idempotent intent and must still reach
        // the daemon, because the earlier request may have failed or been lost.
        if sameText, source == .remote { return true }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return true }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
        // A remote tmux mirror tab rename propagates to `rename-window`.
        if propagateToRemoteTmux, isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleMirrorWindowRenamed(
                workspaceId: id, panelId: panelId, title: trimmed
            )
        }
        // A pane projecting a cloud terminal writes an admitted user/agent rename or clear through
        // to the machine's daemon tab name (`tab rename`): persisted there,
        // broadcast, and shown by every attached client (tree rows, other Macs,
        // TUI tab bars).
        if let resource = cloudResourceForPropagation, resource.kind == .terminal {
            catalog.propagateCloudTerminalRename(
                workspace: self,
                panelID: panelId,
                resource: resource,
                name: trimmed,
                previousCustomTitle: previous,
                previousCustomTitleSource: previousSource
            )
        }
        return true
    }

}
