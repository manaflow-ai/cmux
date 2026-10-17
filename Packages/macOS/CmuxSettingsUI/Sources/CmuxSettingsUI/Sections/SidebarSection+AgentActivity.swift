import CmuxSettings
import SwiftUI

extension SidebarSection {
    @ViewBuilder
    var agentActivityRows: some View {
        agentUsageRow

        SettingsCardRow(
            configurationReview: .json("sidebar.showAgentActivity"),
            String(localized: "settings.app.showAgentActivity", defaultValue: "Show Loading Spinner"),
            subtitle: String(localized: "settings.app.showAgentActivity.subtitle", defaultValue: "Show a loading spinner on workspaces with running coding agents or active loaders. Stays visible even when sidebar details are hidden.")
        ) {
            Toggle("", isOn: Binding(get: { showAgentActivity.current }, set: { showAgentActivity.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.showAgentSessions"),
            String(localized: "settings.app.showAgentSessions", defaultValue: "Show Agent Sessions"),
            subtitle: String(localized: "settings.app.showAgentSessions.subtitle", defaultValue: "List each workspace's live coding-agent sessions under its title: state, the agent's own title, age, and your last prompt.")
        ) {
            Toggle("", isOn: Binding(get: { showAgentSessions.current }, set: { showAgentSessions.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.loadingSpinnerPosition"),
            String(localized: "settings.app.loadingSpinnerPosition", defaultValue: "Loading Spinner Position"),
            subtitle: String(localized: "settings.app.loadingSpinnerPosition.subtitle", defaultValue: "Show the spinner on the left (sharing the unread badge slot) or the right of the workspace row.")
        ) {
            Picker("", selection: Binding(
                get: { loadingSpinnerPosition.current },
                set: { loadingSpinnerPosition.set($0) }
            )) {
                ForEach(SidebarIndicatorPosition.allCases, id: \.self) { position in
                    Text(positionLabel(position)).tag(position)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!showAgentActivity.current)
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.notificationBadgePosition"),
            String(localized: "settings.app.notificationBadgePosition", defaultValue: "Notification Badge Position"),
            subtitle: String(localized: "settings.app.notificationBadgePosition.subtitle", defaultValue: "Show the unread notification badge on the left or the right of the workspace row.")
        ) {
            Picker("", selection: Binding(
                get: { notificationBadgePosition.current },
                set: { notificationBadgePosition.set($0) }
            )) {
                ForEach(SidebarIndicatorPosition.allCases, id: \.self) { position in
                    Text(positionLabel(position)).tag(position)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        SettingsCardDivider()
    }

    private func positionLabel(_ position: SidebarIndicatorPosition) -> String {
        switch position {
        case .leading:
            String(localized: "settings.app.loadingSpinnerPosition.left", defaultValue: "Left")
        case .trailing:
            String(localized: "settings.app.loadingSpinnerPosition.right", defaultValue: "Right")
        }
    }
}
