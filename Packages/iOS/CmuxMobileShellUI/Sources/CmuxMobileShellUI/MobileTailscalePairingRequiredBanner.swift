import CmuxMobileSupport
import SwiftUI

/// Recovery chrome for a Tailscale selection with no local endpoint grant.
struct MobileTailscalePairingRequiredBanner: View {
    let scanPairingCode: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Label(
                    L10n.string(
                        "mobile.tailscalePairingRequired.title",
                        defaultValue: "Finish Tailscale setup"
                    ),
                    systemImage: "qrcode.viewfinder"
                )
                .font(.headline)

                Spacer(minLength: 8)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"))
                .accessibilityIdentifier("MobileTailscalePairingRequiredDismiss")
            }

            Text(MobilePairingScannerSheet.guidanceText)
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
