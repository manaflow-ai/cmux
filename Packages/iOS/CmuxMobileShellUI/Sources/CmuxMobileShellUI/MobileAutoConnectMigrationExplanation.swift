#if os(iOS)
import CmuxMobileShell
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
        Text(String(
            format: L10n.string(
                "mobile.autoConnectMigration.bodyFormat",
                defaultValue: "Iroh needs %@ on your Mac for its authenticated, end-to-end encrypted connection."
            ),
            MobileMacPairingFloor.requiredMacVersionLabel
        ))
        .font(.body)
        .accessibilityIdentifier("MobileAutoConnectMigrationBody")
    }

    private var guidance: some View {
        // Below the floor there is no Tailscale fallback anymore (a legacy
        // Tailscale-only pairing is exactly what this build refuses to dial),
        // so the secondary line is the shared revert path instead of the old
        // "0.64.17 still works over Tailscale" claim.
        Text(MobileMacPairingFloor.revertGuidance)
        .font(.body)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("MobileAutoConnectMigrationGuidance")
    }
}
#endif
