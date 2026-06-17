import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#endif

/// A compact warning that this device has no active tailnet, with a one-tap
/// App Store path. Shown by the pairing screen and the disconnected shell when
/// ``CmuxMobileTransport/TailscaleStatusMonitor`` reports
/// `.inactiveOrNotInstalled`, so connection failures stop looking like
/// mysterious hangs.
///
/// The detector cannot tell "not installed" from "installed but off" (the
/// Tailscale iOS app declares no URL scheme), so the copy covers both and the
/// App Store product page is the single action: it shows "Open" when the app
/// is installed and "Get" when it is not.
struct TailscaleInactiveCallout: View {
    let context: TailscaleInactiveCalloutContext
    @Environment(\.analytics) private var analytics

    private static let appStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Link(destination: Self.appStoreURL) {
                Label(
                    L10n.string("mobile.tailscale.appStoreLink", defaultValue: "Open Tailscale in the App Store"),
                    systemImage: "arrow.down.app"
                )
                .font(.footnote.weight(.medium))
            }
        }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileTailscaleInactiveCallout")
        .onAppear {
            analytics.capture(
                "ios_tailscale_inactive_callout_shown",
                ["context": .string(context.rawValue)]
            )
        }
    }

    private var title: String {
        let format = L10n.string(
            "mobile.tailscale.inactiveTitleFormat",
            defaultValue: "Tailscale is not active on this %@"
        )
        return String(format: format, deviceModel)
    }

    private var detail: String {
        switch context {
        case .pairing:
            return L10n.string(
                "mobile.tailscale.pairingHelp",
                defaultValue: "QR pairing usually needs both devices on the same Tailscale network. Turn Tailscale on first, or pair by host and port on a trusted local network."
            )
        case .disconnected:
            return L10n.string(
                "mobile.tailscale.disconnectedHelp",
                defaultValue: "Your Mac may be unreachable because Tailscale is off here. Turn it on, then try again."
            )
        }
    }

    private var deviceModel: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        L10n.string("mobile.tailscale.genericDevice", defaultValue: "device")
        #endif
    }
}
