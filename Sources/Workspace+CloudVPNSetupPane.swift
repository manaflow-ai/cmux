import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func newCloudVPNSetupSurface(inPane paneId: PaneID, coordinator: CloudTunnelCoordinator?, focus: Bool = true) -> CloudVPNSetupPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let panel = CloudVPNSetupPanel(coordinator: coordinator)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: "cloud_vpn_setup",
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }
        bindSurface(tabId, toPanelId: panel.id)
        publishCmuxSurfaceCreated(panel.id, paneId: paneId, kind: "cloud_vpn_setup", origin: "cloud_vpn_setup_workspace", focused: focus)
        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
        return panel
    }

    @discardableResult
    func openOrFocusCloudVPNSetupSurface(inPane paneId: PaneID, coordinator: CloudTunnelCoordinator?, focus: Bool = true) -> CloudVPNSetupPanel? {
        if let existing = panels.values.compactMap({ $0 as? CloudVPNSetupPanel }).first {
            if focus { focusPanel(existing.id) }
            return existing
        }
        return newCloudVPNSetupSurface(inPane: paneId, coordinator: coordinator, focus: focus)
    }
}
