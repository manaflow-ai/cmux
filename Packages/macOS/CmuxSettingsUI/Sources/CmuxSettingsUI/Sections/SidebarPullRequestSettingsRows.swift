import SwiftUI

@MainActor
struct SidebarPullRequestSettingsRows: View {
    let hideAll: DefaultsValueModel<Bool>
    let showPR: DefaultsValueModel<Bool>
    let showPRCI: DefaultsValueModel<Bool>
    let prClickable: DefaultsValueModel<Bool>
    let prLinks: DefaultsValueModel<Bool>

    var body: some View {
        showPullRequestsRow
        SettingsCardDivider()
        showPullRequestCIStatusRow
        SettingsCardDivider()
        makePullRequestsClickableRow
        SettingsCardDivider()
        openPullRequestLinksRow
        SettingsCardDivider()
    }

    private var showPullRequestsRow: some View {
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
    }

    private var showPullRequestCIStatusRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showPullRequestCIStatus"),
            String(localized: "settings.app.showPullRequestCIStatus", defaultValue: "Show PR CI Status in Sidebar"),
            subtitle: String(localized: "settings.app.showPullRequestCIStatus.subtitle", defaultValue: "Display a CI result indicator next to open pull request rows.")
        ) {
            Toggle("", isOn: Binding(get: { showPRCI.current }, set: { showPRCI.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current || !showPR.current)
    }

    private var makePullRequestsClickableRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.makePullRequestsClickable"),
            String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"),
            subtitle: String(localized: "settings.app.makeSidebarPullRequestClickable.subtitle", defaultValue: "Review items stay visible as plain text, and clicks in that area select the workspace row.")
        ) {
            Toggle("", isOn: Binding(get: { prClickable.current }, set: { prClickable.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSidebarPullRequestClickableToggle")
        }
        .disabled(hideAll.current || !showPR.current)
    }

    private var openPullRequestLinksRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.openPullRequestLinksInCmuxBrowser"),
            String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"),
            subtitle: prLinksSubtitle
        ) {
            Toggle("", isOn: Binding(get: { prLinks.current }, set: { prLinks.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current || !showPR.current || !prClickable.current)
    }

    private var prLinksSubtitle: String {
        if !showPR.current {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleHidden", defaultValue: "Enable sidebar PR visibility to choose where PR links open.")
        }
        if !prClickable.current {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleDisabled", defaultValue: "Enable sidebar PR clickability to choose where PR links open.")
        }
        return prLinks.current
            ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside cmux browser.")
            : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")
    }
}
