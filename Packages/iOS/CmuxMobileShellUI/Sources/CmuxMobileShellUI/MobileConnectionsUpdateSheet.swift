#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One-time "what's new" sheet for the per-Computer connection-method update,
/// shown on first launch after updating for users who already have Computers
/// (fresh installs learn the same things in onboarding). Duolingo-style: a
/// gradient hero, a ribbon, bold feature rows, one big capsule CTA.
struct MobileConnectionsUpdateSheet: View {
    /// Defaults key marking the notice as acknowledged on this device.
    static let acknowledgedKey = "dev.cmux.mobile.connectionsUpdateNotice.v1"

    let dismiss: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.55), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    ribbon
                    Text(L10n.string(
                        "mobile.connectionsUpdate.title",
                        defaultValue: "Every computer, its own connection"
                    ))
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                    VStack(spacing: 16) {
                        featureRow(
                            symbol: "desktopcomputer.and.macbook",
                            tint: .blue,
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
                            symbol: "bolt.horizontal.circle.fill",
                            tint: .purple,
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
                            tint: .green,
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
                            tint: .orange,
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
                    .padding(.horizontal, 20)
                    Button(action: dismiss) {
                        Text(L10n.string(
                            "mobile.connectionsUpdate.cta",
                            defaultValue: "Got It"
                        ))
                        .font(.system(.headline, design: .rounded).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(Color.black.opacity(0.85))
                    }
                    .accessibilityIdentifier("MobileConnectionsUpdateGotIt")
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .padding(.top, 28)
            }
        }
        .accessibilityIdentifier("MobileConnectionsUpdateSheet")
    }

    private var ribbon: some View {
        Text(L10n.string(
            "mobile.connectionsUpdate.ribbon",
            defaultValue: "WHAT'S NEW"
        ))
        .font(.system(.subheadline, design: .rounded).bold())
        .tracking(2)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Color.black.opacity(0.85))
    }

    private func featureRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
