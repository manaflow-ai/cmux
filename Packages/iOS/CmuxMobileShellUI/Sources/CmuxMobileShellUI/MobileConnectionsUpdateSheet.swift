#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One-time "what's new" sheet for the per-Computer connection-method update,
/// shown on first launch after updating for users who already have Computers
/// (fresh installs learn the same things in onboarding). Follows the system
/// What's New template: plain background, centered title, accent-tinted
/// symbol rows, one prominent Continue button.
struct MobileConnectionsUpdateSheet: View {
    /// Defaults key marking the notice as acknowledged on this device.
    static let acknowledgedKey = "dev.cmux.mobile.connectionsUpdateNotice.v1"

    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 36) {
                    Text(L10n.string(
                        "mobile.connectionsUpdate.title",
                        defaultValue: "What's New in cmux"
                    ))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 56)
                    .padding(.horizontal, 32)
                    VStack(alignment: .leading, spacing: 28) {
                        featureRow(
                            symbol: "desktopcomputer.and.macbook",
                            title: L10n.string(
                                "mobile.connectionsUpdate.perComputer.title",
                                defaultValue: "Per-computer methods"
                            ),
                            detail: L10n.string(
                                "mobile.connectionsUpdate.perComputer.detail",
                                defaultValue: "Each computer now picks how this iPhone reaches it: Iroh, Tailscale Only, or Direct. Set it in Computers → your computer → Connection Method."
                            )
                        )
                        featureRow(
                            symbol: "bolt.horizontal",
                            title: L10n.string(
                                "mobile.connectionsUpdate.iroh.title",
                                defaultValue: "Auto-Connect is now Iroh"
                            ),
                            detail: L10n.string(
                                "mobile.connectionsUpdate.iroh.detail",
                                defaultValue: "Same authenticated, end-to-end encrypted connection — clearer name. The app-wide setting moved out of Settings."
                            )
                        )
                        featureRow(
                            symbol: "network",
                            title: L10n.string(
                                "mobile.connectionsUpdate.direct.title",
                                defaultValue: "New: Direct addresses"
                            ),
                            detail: L10n.string(
                                "mobile.connectionsUpdate.direct.detail",
                                defaultValue: "On your LAN, WireGuard, or any other network: add the addresses where a computer is reachable and dial exactly those — no fallback."
                            )
                        )
                        featureRow(
                            symbol: "qrcode.viewfinder",
                            title: L10n.string(
                                "mobile.connectionsUpdate.tailscale.title",
                                defaultValue: "Tailscale, on your terms"
                            ),
                            detail: L10n.string(
                                "mobile.connectionsUpdate.tailscale.detail",
                                defaultValue: "Choosing Tailscale Only shows exactly what's missing and offers the pairing-code scan right there — nothing opens on its own."
                            )
                        )
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
            Button(action: dismiss) {
                Text(L10n.string(
                    "mobile.connectionsUpdate.cta",
                    defaultValue: "Continue"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .accessibilityIdentifier("MobileConnectionsUpdateGotIt")
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileConnectionsUpdateSheet")
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
