#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MobileAutoConnectMigrationExplanation()
                    MobileAutoConnectMigrationActions(
                        continueWithAutoConnect: continueWithAutoConnect,
                        openConnectionSettings: openConnectionSettings
                    )
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .accessibilityIdentifier("MobileAutoConnectMigrationScrollView")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAutoConnectMigrationSheet")
    }
}
#endif
