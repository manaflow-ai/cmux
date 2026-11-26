import Bonsplit
import CmuxCloud
import CmuxWorkspaces
import Foundation

/// Transient workspace surface for Cloud VPN setup. Reading it never activates
/// the VPN; only its Connect control does.
@MainActor
final class CloudVPNSetupPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVPNSetup
    let model: CloudVPNSetupModel

    var displayTitle: String {
        String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN")
    }

    var displayIcon: String? { "network" }

    init(coordinator: CloudTunnelCoordinator?) {
        model = CloudVPNSetupModel(coordinator: coordinator)
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}

extension Workspace {
    @discardableResult
    func newCloudVPNSetupSurface(
        inPane paneID: PaneID,
        coordinator: CloudTunnelCoordinator?,
        focus: Bool = true
    ) -> CloudVPNSetupPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let panel = CloudVPNSetupPanel(coordinator: coordinator)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabID = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.cloudVPNSetup.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneID
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        bindSurface(tabID, toPanelId: panel.id)
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneID,
            kind: SurfaceKind.cloudVPNSetup.rawValue,
            origin: "cloud_vpn_setup_workspace",
            focused: focus
        )
        if focus {
            bonsplitController.focusPane(paneID)
            bonsplitController.selectTab(tabID)
            applyTabSelection(tabId: tabID, inPane: paneID)
        }
        return panel
    }
}
