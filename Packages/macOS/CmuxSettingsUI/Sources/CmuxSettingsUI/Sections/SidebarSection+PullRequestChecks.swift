import CmuxSettings
import SwiftUI

@MainActor
extension SidebarSection {
    @ViewBuilder
    var pullRequestVisibilitySettingsRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showPullRequests"),
            String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
            subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status and number.")
        ) {
            Toggle("", isOn: Binding(get: { showPR.current }, set: { showPR.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current)
        SettingsCardDivider()
    }

    @ViewBuilder
    var pullRequestChecksSettingsRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showPullRequestChecks"),
            String(localized: "settings.app.showPullRequestChecks", defaultValue: "Show Pull Request Checks"),
            subtitle: String(localized: "settings.app.showPullRequestChecks.subtitle", defaultValue: "Show a compact pass, fail, or pending status beside each pull request. Hover it for individual checks and merge conflicts.")
        ) {
            Toggle("", isOn: Binding(get: { showPRChecks.current }, set: { showPRChecks.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current || !showPR.current)
        SettingsCardDivider()
    }
}
