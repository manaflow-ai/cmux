import CmuxMobileSupport
import SwiftUI

/// Persistent recovery chrome for a Tailscale selection with no local endpoint grant.
struct MobileTailscalePairingRequiredBanner: View {
    let scanPairingCode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string(
                    "mobile.tailscalePairingRequired.title",
                    defaultValue: "Finish Tailscale setup"
                ),
                systemImage: "qrcode.viewfinder"
            )
            .font(.headline)

            Text(L10n.string(
                "mobile.tailscalePairingRequired.description",
                defaultValue: "On cmux 0.64.17, choose Connect iPhone/iPad. On newer versions, open Tailscale Pairing. Then scan the code here once."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button(action: scanPairingCode) {
                Text(L10n.string(
                    "mobile.tailscalePairingRequired.scan",
                    defaultValue: "Scan Pairing Code"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobileTailscalePairingRequiredScan")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileTailscalePairingRequiredBanner")
    }
}
