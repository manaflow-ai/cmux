import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation

/// Installs the temporary panel used while a Cloud terminal split is materialized.
extension Workspace {
    /// Adds a visible pending panel to an empty Bonsplit pane.
    ///
    /// Returns nil when the pane disappeared, was claimed by another action, or
    /// Bonsplit could not create the placeholder tab. In those cases the caller
    /// must not fall through to local terminal creation.
    @discardableResult
    func installCloudTerminalPendingPanel(
        machine: SurfaceMachineID,
        in pane: PaneID
    ) -> CloudTerminalPendingPanel? {
        guard bonsplitController.allPaneIds.contains(pane),
              bonsplitController.tabs(inPane: pane).isEmpty else { return nil }
        let pending = CloudTerminalPendingPanel(workspaceId: id, machine: machine)
        panels[pending.id] = pending
        panelTitles[pending.id] = pending.displayTitle
        guard let tab = bonsplitController.createTab(
            title: pending.displayTitle,
            icon: pending.displayIcon,
            kind: SurfaceKind.cloudVMLoading.rawValue,
            isDirty: false,
            isLoading: true,
            isPinned: false,
            inPane: pane
        ) else {
            panels.removeValue(forKey: pending.id)
            panelTitles.removeValue(forKey: pending.id)
            return nil
        }
        bindSurface(tab, toPanelId: pending.id)
        return pending
    }
}
