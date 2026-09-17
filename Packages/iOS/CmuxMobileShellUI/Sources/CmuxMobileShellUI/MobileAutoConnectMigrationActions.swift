#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The two explicit outcomes offered by the migration notice.
struct MobileAutoConnectMigrationActions: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: continueWithAutoConnect) {
                Text(L10n.string(
                    "mobile.autoConnectMigration.continue",
                    defaultValue: "Continue with Auto-Connect"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("MobileAutoConnectMigrationContinue")

            Button(action: openConnectionSettings) {
                Text(L10n.string(
                    "mobile.autoConnectMigration.openSettings",
                    defaultValue: "Open Connection Settings"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("MobileAutoConnectMigrationOpenSettings")
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
