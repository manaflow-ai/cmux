import CmuxSettings
import SwiftUI

struct SidebarNotificationSchedulerPickerRow: View {
    @Binding var mode: SidebarNotificationSchedulerMode

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.notificationSchedulerMode"),
            String(localized: "settings.sidebar.notificationSchedulerMode", defaultValue: "Notification Scheduler"),
            subtitle: String(
                localized: "settings.sidebar.notificationSchedulerMode.subtitle",
                defaultValue: "Choose how unread notification workspaces are prioritized in the sidebar."
            ),
            controlWidth: 190
        ) {
            Picker("", selection: $mode) {
                ForEach(SidebarNotificationSchedulerMode.allCases, id: \.self) { mode in
                    Text(title(for: mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func title(for mode: SidebarNotificationSchedulerMode) -> String {
        switch mode {
        case .smartUrgency:
            return String(localized: "settings.sidebar.notificationSchedulerMode.smartUrgency", defaultValue: "Smart Urgency")
        case .blockedFirst:
            return String(localized: "settings.sidebar.notificationSchedulerMode.blockedFirst", defaultValue: "Blocked First")
        case .smallWins:
            return String(localized: "settings.sidebar.notificationSchedulerMode.smallWins", defaultValue: "Small Wins")
        case .aging:
            return String(localized: "settings.sidebar.notificationSchedulerMode.aging", defaultValue: "Aging")
        case .roundRobin:
            return String(localized: "settings.sidebar.notificationSchedulerMode.roundRobin", defaultValue: "Round Robin")
        case .arrivalOrder:
            return String(localized: "settings.sidebar.notificationSchedulerMode.arrivalOrder", defaultValue: "Arrival Order")
        }
    }
}

extension SidebarSection {
    func prLinksSubtitle(prVisible: Bool, prClickable: Bool, openInCmux: Bool) -> String {
        if !prVisible {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleHidden", defaultValue: "Enable sidebar PR visibility to choose where PR links open.")
        }
        if !prClickable {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleDisabled", defaultValue: "Enable sidebar PR clickability to choose where PR links open.")
        }
        return openInCmux
            ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside cmux browser.")
            : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")
    }
}
