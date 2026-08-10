#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The complete localized explanation shown by the migration notice.
struct MobileAutoConnectMigrationExplanation: View {
    var body: some View {
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
                .accessibilityIdentifier("MobileAutoConnectMigrationBody")

                Text(L10n.string(
                    "mobile.autoConnectMigration.guidance",
                    defaultValue: "Prefer your previous setup? Open Settings → Connection Method and choose Tailscale Only."
                ))
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("MobileAutoConnectMigrationGuidance")
            }
        }
    }
}
#endif
