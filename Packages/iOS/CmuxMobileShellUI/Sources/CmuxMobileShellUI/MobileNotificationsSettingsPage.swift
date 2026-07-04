#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileNotificationsSettingsPage: View {
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @State private var notificationsEnabled = false

    var body: some View {
        Form {
            Section(L10n.string("mobile.settings.notifications", defaultValue: "Notifications")) {
                Button {
                    Task {
                        if notificationsEnabled {
                            await pushCoordinator.disable()
                            notificationsEnabled = false
                        } else {
                            notificationsEnabled = await pushCoordinator.enable()
                        }
                    }
                } label: {
                    Label(
                        notificationsEnabled
                            ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications")
                            : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me About Agents"),
                        systemImage: notificationsEnabled ? "bell.slash" : "bell"
                    )
                }
                .accessibilityIdentifier("MobileSettingsNotifications")
            }
        }
        .onAppear { notificationsEnabled = pushCoordinator.isEnabled }
        .navigationTitle(L10n.string("mobile.settings.notifications", defaultValue: "Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsNotificationsPage")
    }
}
#endif
