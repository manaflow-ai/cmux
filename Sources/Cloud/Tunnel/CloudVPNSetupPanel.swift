import AppKit
import Foundation

@MainActor
final class CloudVPNSetupPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVPNSetup

    let model: CloudVPNSetupModel

    init(coordinator: CloudTunnelCoordinator?) {
        model = CloudVPNSetupModel(coordinator: coordinator)
    }

    var displayTitle: String {
        String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN")
    }

    var displayIcon: String? { "network" }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}
