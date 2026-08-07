#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Auto-Connect vs Tailscale connection-method choice, shared by Settings
/// and (through the same store) onboarding. Choosing Tailscale surfaces the
/// pairing-code scanner entry, because a user-entered code is what authorizes
/// each Mac's Tailscale destination.
struct MobileConnectionMethodSection: View {
    @Bindable var store: MobileConnectionMethodStore
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
                Text(L10n.string(
                    "mobile.settings.connectionMethod.tailscale",
                    defaultValue: "Tailscale Only"
                ))
                .tag(MobileConnectionMethod.tailscale)
            }
            .accessibilityIdentifier("MobileSettingsConnectionMethod")
            if store.method == .tailscale, startPairingScanner != nil {
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
                .accessibilityIdentifier("MobileSettingsTailscaleScanButton")
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
                defaultValue: "Connects to your Mac automatically over an end-to-end encrypted connection, directly or through cmux relays. No setup needed."
            )
        case .tailscale:
            L10n.string(
                "mobile.settings.connectionMethod.tailscaleFooter",
                defaultValue: """
                Connects only over Tailscale. If unavailable, cmux stays disconnected instead of using Iroh. \
                Install Tailscale on both devices, join the same network, then scan the pairing code shown by \
                cmux on your Mac once.
                """
            )
        }
    }
}
#endif
