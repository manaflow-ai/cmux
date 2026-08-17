#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The two explicit outcomes offered by the migration notice.
struct MobileAutoConnectMigrationActions: View {
    let useAutoConnect: () -> Void
    let setUpTailscale: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: useAutoConnect) {
                Text(L10n.string(
                    "mobile.autoConnectMigration.useAutoConnect",
                    defaultValue: "Use Auto-Connect"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("MobileAutoConnectMigrationUseAutoConnect")

            Button(action: setUpTailscale) {
                Text(L10n.string(
                    "mobile.autoConnectMigration.setUpTailscale",
                    defaultValue: "Set Up Tailscale"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("MobileAutoConnectMigrationSetUpTailscale")
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
