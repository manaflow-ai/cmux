import CmuxFoundation
import SwiftUI

@MainActor
struct IntegrationAccountRow: View {
    let account: IntegrationAccountSettingsSnapshot
    let statusText: String
    let onNotificationsChanged: (Bool) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:integrations:\(account.source.rawValue):\(account.accountID)",
            account.displayName,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { account.notificationsEnabled },
                        set: { onNotificationsChanged($0) }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
                .help(String(localized: "settings.integrations.notifications.tooltip", defaultValue: "cmux-native notifications"))

                Button(String(localized: "settings.integrations.disconnect", defaultValue: "Disconnect"), action: onDisconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var subtitle: String {
        var parts = [statusText]
        if account.credentialState == "present" {
            parts.append(String(localized: "settings.integrations.credential.keychain", defaultValue: "Credential in Keychain"))
        }
        if !account.capabilities.isEmpty {
            parts.append(account.capabilities.joined(separator: ", "))
        }
        if let lastSyncDescription = account.lastSyncDescription {
            parts.append(lastSyncDescription)
        }
        return parts.joined(separator: " - ")
    }
}
