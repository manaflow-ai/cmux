#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .vertical) {
                MobileAutoConnectMigrationContent(
                    continueWithAutoConnect: continueWithAutoConnect,
                    openConnectionSettings: openConnectionSettings
                )
                .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    MobileAutoConnectMigrationContent(
                        continueWithAutoConnect: continueWithAutoConnect,
                        openConnectionSettings: openConnectionSettings
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("MobileAutoConnectMigrationScrollView")
            }
        }
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAutoConnectMigrationSheet")
    }
}

private struct MobileAutoConnectMigrationContent: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
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
        .accessibilityIdentifier("MobileAutoConnectMigrationContent")
    }
}
#endif
