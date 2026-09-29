#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The outcome offered by the migration notice.
struct MobileAutoConnectMigrationActions: View {
    let useAutoConnect: () -> Void

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
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
