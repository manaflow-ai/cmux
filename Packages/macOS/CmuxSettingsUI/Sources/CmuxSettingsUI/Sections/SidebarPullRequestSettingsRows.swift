import CmuxSettings
import SwiftUI

@MainActor
struct SidebarPullRequestSettingsRows: View {
    @Binding var showPR: Bool
    @Binding var showChecks: Bool
    let hideAll: Bool

    var body: some View {
        visibilityRow
        checksRow
    }

    @ViewBuilder
    private var visibilityRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showPullRequests"),
            String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
            subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status and number.")
        ) {
            Toggle("", isOn: $showPR)
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll)
        SettingsCardDivider()
    }

    @ViewBuilder
    private var checksRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showPullRequestChecks"),
            String(localized: "settings.app.showPullRequestChecks", defaultValue: "Show Pull Request Checks"),
            subtitle: String(localized: "settings.app.showPullRequestChecks.subtitle", defaultValue: "Show a compact pass, fail, or pending status beside each pull request. Hover it for individual checks and merge conflicts.")
        ) {
            Toggle("", isOn: $showChecks)
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll || !showPR)
        SettingsCardDivider()
    }
}
