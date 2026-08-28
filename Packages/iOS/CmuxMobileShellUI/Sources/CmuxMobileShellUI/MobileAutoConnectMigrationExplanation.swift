#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The complete localized explanation shown by the migration notice.
struct MobileAutoConnectMigrationExplanation: View {
    let layout: MobileAutoConnectMigrationLayout

    var body: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 24) {
                icon
                explanation
            }
        case .compact:
            VStack(alignment: .leading, spacing: 12) {
                title
                bodyText
                guidance
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            bodyText
            guidance
        }
    }

    private var icon: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.largeTitle)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(L10n.string(
            "mobile.autoConnectMigration.title",
            defaultValue: "Check cmux on your Mac"
        ))
        .font(.title.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("MobileAutoConnectMigrationTitle")
    }

    private var bodyText: some View {
        Text(L10n.string(
            "mobile.autoConnectMigration.body",
            defaultValue: "Iroh needs cmux 0.64.20 or later on your Mac for its authenticated, end-to-end encrypted connection."
        ))
        .font(.body)
        .accessibilityIdentifier("MobileAutoConnectMigrationBody")
    }

    private var guidance: some View {
        Text(L10n.string(
            "mobile.autoConnectMigration.guidance",
            defaultValue: "Older cmux versions still work over Tailscale. Open Tailscale Pairing on the Mac and scan its QR, or enter its numeric Tailscale IP and port once."
        ))
        .font(.body)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("MobileAutoConnectMigrationGuidance")
    }
}
#endif
