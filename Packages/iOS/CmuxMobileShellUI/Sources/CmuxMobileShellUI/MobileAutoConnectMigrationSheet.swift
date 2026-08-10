#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.string(
                            "mobile.autoConnectMigration.title",
                            defaultValue: "cmux now uses Auto-Connect"
                        ))
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)

                        Text(L10n.string(
                            "mobile.autoConnectMigration.body",
                            defaultValue: "Auto-Connect works without Tailscale. It uses an end-to-end encrypted connection, directly when possible and through cmux relays when needed."
                        ))
                        .font(.body)

                        Text(L10n.string(
                            "mobile.autoConnectMigration.guidance",
                            defaultValue: "Prefer your previous setup? Open Settings → Connection Method and choose Tailscale Only."
                        ))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAutoConnectMigrationSheet")
    }
}
#endif
