#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The explicit transport-mode choice, shared by Settings and onboarding.
/// Choosing Tailscale still surfaces the pairing-code scanner entry, because a
/// user-entered code is what authorizes each Mac's Tailscale destination.
struct MobileConnectionMethodSection: View {
    @Bindable var store: MobileConnectionMethodStore
    let hasUsableTailscaleAuthorization: Bool
    let startPairingScanner: (() -> Void)?

    var body: some View {
        Section {
            Picker(
                L10n.string(
                    "mobile.settings.connectionMethod",
                    defaultValue: "Connection Method"
                ),
                selection: $store.method
            ) {
                Text(L10n.string(
                    "mobile.settings.connectionMethod.automatic",
                    defaultValue: "Auto-Connect"
                ))
                .tag(MobileConnectionMethod.automatic)
                .accessibilityIdentifier("MobileSettingsConnectionMethodAutomatic")
                Text(L10n.string(
                    "mobile.settings.connectionMethod.tailscale",
                    defaultValue: "Tailscale Only"
                ))
                .tag(MobileConnectionMethod.tailscale)
                .accessibilityIdentifier("MobileSettingsConnectionMethodTailscale")
                Text(L10n.string(
                    "mobile.settings.connectionMethod.lan",
                    defaultValue: "LAN Only"
                ))
                .tag(MobileConnectionMethod.lan)
                .accessibilityIdentifier("MobileSettingsConnectionMethodLAN")
                Text(L10n.string(
                    "mobile.settings.connectionMethod.iroh",
                    defaultValue: "iroh Only"
                ))
                .tag(MobileConnectionMethod.iroh)
                .accessibilityIdentifier("MobileSettingsConnectionMethodIroh")
            }
            .accessibilityIdentifier("MobileSettingsConnectionMethod")
            .onChange(of: store.method) { previousMethod, method in
                guard method == .tailscale || method == .lan,
                      previousMethod != method,
                      method != .tailscale || !hasUsableTailscaleAuthorization else {
                    return
                }
                startPairingScanner?()
            }
            if (store.method == .tailscale || store.method == .lan),
               startPairingScanner != nil {
                Button {
                    startPairingScanner?()
                } label: {
                    Label(
                        L10n.string(
                            "mobile.settings.connectionMethod.scanCode",
                            defaultValue: "Scan Pairing Code"
                        ),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier(
                    store.method == .lan
                        ? "MobileSettingsLANScanButton"
                        : "MobileSettingsTailscaleScanButton"
                )
            }
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        switch store.method {
        case .automatic:
            L10n.string(
                "mobile.settings.connectionMethod.automaticFooter",
                defaultValue: "Requires cmux 0.64.20 or later on your Mac. Connects automatically over an authenticated, end-to-end encrypted connection."
            )
        case .tailscale:
            L10n.string(
                "mobile.settings.connectionMethod.tailscaleFooter",
                defaultValue: """
                Works with cmux 0.64.17 or later on your Mac. Install Tailscale on both devices, join the same \
                network, then scan the Mac's pairing code once. cmux stays disconnected until that local \
                authorization exists.
                """
            )
        case .lan:
            L10n.string(
                "mobile.settings.connectionMethod.lanFooter",
                defaultValue: "Uses only the Mac's local-network address. If the devices are not on the same network, cmux stays disconnected and does not switch to another transport."
            )
        case .iroh:
            L10n.string(
                "mobile.settings.connectionMethod.irohFooter",
                defaultValue: "Uses only authenticated iroh paths (direct or relay). LAN and Tailscale routes are not used."
            )
        }
    }
}
#endif
