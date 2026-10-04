import Bonsplit
import Foundation

/// Local title ownership; Cloud requests enter the catalog before any UI mutation.
extension Workspace {
    /// Sets, replaces, or clears (empty/nil `title`) a panel custom title.
    ///
    /// `.auto` writes are rejected when a user or remote title exists, and
    /// `.auto` never clears. `.remote` is the cloud daemon's canonical value and
    /// may replace a local title. Returns whether the write landed.
    @discardableResult
    func setPanelCustomTitle(
        panelId: UUID,
        title: String?,
        source: CustomTitleSource = .user,
        propagateToRemoteTmux: Bool = true,
        propagateToCloud: Bool = true
    ) -> Bool {
        let remoteTmuxPane = remoteTmuxControlPane(surfaceID: panelId)
        // Projected tmux panes are represented by their mirror, rather than in
        // the workspace's ordinary panel dictionary. They are still valid
        // title targets and must reach `select-pane -T`.
        guard panels[panelId] != nil || remoteTmuxPane != nil else { return false }
        // A remote tmux projection owns its title on tmux. Do not let the
        // cloud-title bridge consume this local edit before it can be sent to
        // the pane's `select-pane -T` control mutation.
        if propagateToCloud, source != .remote, remoteTmuxPane == nil,
           let submitted = SurfaceCatalog.shared.submitCloudPanelRename(
               workspace: self, panelID: panelId, title: title, source: source
           ) { return submitted }
        let previousWorkspaceTitle = self.title
        defer {
            if self.title != previousWorkspaceTitle {
                owningTabManager?.panelCustomTitleDidReconcileWorkspaceTitle(self)
            }
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if source == .auto {
            guard !trimmed.isEmpty, cloudProjectedResource(forPanel: panelId) == nil else { return false }
            if previous != nil, (panelCustomTitleSources[panelId] ?? .user) != .auto { return false }
        }
        var sameText = false
        if trimmed.isEmpty {
            // `select-pane -T ''` is meaningful even when cmux has no local
            // custom-title record: tmux may still hold a title set outside cmux.
            // Do not suppress this reset merely because there is no local state.
            guard previous != nil else {
                if propagateToRemoteTmux, let remoteTmuxPane {
                    _ = remoteTmuxPane.requestRename(title: "")
                    return true
                }
                return false
            }
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

        // A repeated remote or automatic observation only changes provenance.
        // A repeated USER edit remains an idempotent intent and must still reach
        // the daemon, because the earlier request may have failed or been lost.
        if sameText, source != .user { return true }

        let tabId = surfaceIdFromPanelId(panelId)
            ?? (remoteTmuxPane == nil ? nil : TabID(uuid: panelId))
        guard let panel = panels[panelId] ?? remoteTmuxPane?.pane.panel,
              let tabId else { return true }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
        // A remote tmux mirror tab rename propagates to `rename-window`.
        if propagateToRemoteTmux {
            if let remoteTmuxPane {
                _ = remoteTmuxPane.requestRename(title: trimmed)
            } else if isRemoteTmuxMirror {
                AppDelegate.shared?.remoteTmuxController.handleMirrorWindowRenamed(
                    workspaceId: id, panelId: panelId, title: trimmed
                )
            }
        }
        return true
    }

}
