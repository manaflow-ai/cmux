#if os(iOS)
import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Value inputs keep rows independent of the observable session controller.
struct CloudVPNControls: View {
    let phase: CloudSystemVPNPhase
    let enable: () -> Void
    let disable: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("mobile.cloud.vpn.explanation", defaultValue: "Let Safari and other apps reach your Cloud machine's private ports. Terminal access already works inside cmux."))
            Text(L10n.string("mobile.cloud.vpn.notice", defaultValue: "iOS will ask permission to add a VPN. Only Cloud private addresses use it. This may replace another active VPN."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            switch phase {
            case .off:
                Button(L10n.string("mobile.cloud.vpn.enable", defaultValue: "Enable system VPN"), action: enable)
                    .accessibilityIdentifier("CloudVPNEnable")
            case .preparing, .connecting:
                ProgressView(L10n.string("mobile.cloud.vpn.connecting", defaultValue: "Setting up system VPN"))
                    .accessibilityIdentifier("CloudVPNConnecting")
                Button(L10n.string("mobile.cloud.vpn.cancel", defaultValue: "Cancel"), action: disable)
            case .connected:
                Label(L10n.string("mobile.cloud.vpn.connected", defaultValue: "System VPN connected"), systemImage: "checkmark.shield")
                    .accessibilityIdentifier("CloudVPNConnected")
                Button(L10n.string("mobile.cloud.vpn.disconnect", defaultValue: "Disconnect system VPN"), action: disable)
            case .disconnecting:
                ProgressView(L10n.string("mobile.cloud.vpn.disconnecting", defaultValue: "Disconnecting system VPN"))
            case .failed(let error):
                Text(error == .unavailable
                     ? L10n.string("mobile.cloud.vpn.deviceRequired", defaultValue: "System VPN requires a physical iPhone or iPad.")
                     : L10n.string("mobile.cloud.vpn.failed", defaultValue: "System VPN could not start. If you declined permission, try again and tap Allow."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CloudVPNFailure")
                Button(L10n.string("mobile.cloud.vpn.retry", defaultValue: "Try again"), action: enable)
                    .accessibilityIdentifier("CloudVPNRetry")
                Button(L10n.string("mobile.cloud.vpn.settings", defaultValue: "Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .accessibilityIdentifier("CloudVPNSettings")
                Text(L10n.string("mobile.cloud.vpn.recovery", defaultValue: "In Settings, go to General > VPN & Device Management > VPN. If cmux Cloud is missing, return here and try again to add it."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}
#endif
