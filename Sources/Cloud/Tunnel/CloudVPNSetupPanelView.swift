import CmuxCloud
import SwiftUI

/// Hosts ``CloudVPNSetupView`` inside a workspace pane and observes VPN state
/// only while the pane's view is mounted.
struct CloudVPNSetupPanelView: View {
    let model: CloudVPNSetupModel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        CloudVPNSetupView(model: model, openSystemSettings: SystemExtensionSettingsLink.open)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.contentBackgroundColor))
            .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
            .contentShape(Rectangle())
            .onTapGesture { onRequestPanelFocus() }
            // Restarts once a late coordinator attaches, since observing needs one.
            .task(id: model.isAttached) {
                await model.refresh()
                await model.observe()
            }
            .accessibilityIdentifier("CloudVPNSetupPanel")
    }
}
