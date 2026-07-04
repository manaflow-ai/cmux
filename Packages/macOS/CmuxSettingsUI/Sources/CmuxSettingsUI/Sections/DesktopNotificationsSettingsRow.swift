import CmuxFoundation
import SwiftUI

@MainActor
struct DesktopNotificationsSettingsRow: View {
    let state: DesktopNotificationAuthorizationState
    let requestAuthorization: () -> Void
    let openSystemSettings: () -> Void
    let sendTest: () -> Void

    var body: some View {
        let presentation = DesktopNotificationPermissionPresentation.make(for: state)
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:app:desktop-notifications",
            String(localized: "settings.notifications.desktop", defaultValue: "Desktop Notifications"),
            subtitle: presentation.subtitleText
        ) {
            HStack(spacing: 6) {
                Text(presentation.statusText)
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundStyle(statusColor(presentation.statusLabel))
                    .frame(width: 98, alignment: .trailing)
                if let primaryAction = presentation.primaryAction,
                   let primaryActionTitle = presentation.primaryActionTitle {
                    Button(primaryActionTitle) {
                        handlePrimaryAction(primaryAction)
                    }
                    .controlSize(.small)
                }
                Button(String(localized: "settings.notifications.desktop.sendTest", defaultValue: "Send Test")) {
                    sendTest()
                }
                .controlSize(.small)
                .disabled(!presentation.sendTestEnabled)
            }
        }
    }

    private func handlePrimaryAction(_ action: DesktopNotificationPermissionAction) {
        switch action {
        case .requestAuthorization:
            requestAuthorization()
        case .openSystemSettings:
            openSystemSettings()
        }
    }

    private func statusColor(_ status: DesktopNotificationPermissionStatusLabel) -> Color {
        switch status {
        case .allowed, .deliverQuietly, .temporary:
            return .green
        case .denied:
            return .red
        case .unknown, .notRequested:
            return .secondary
        }
    }
}
