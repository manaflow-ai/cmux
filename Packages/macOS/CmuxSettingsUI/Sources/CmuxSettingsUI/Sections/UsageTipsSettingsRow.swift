import CmuxSettings
import SwiftUI

@MainActor
struct UsageTipsSettingsRow: View {
    @LiveSetting(\.app.showUsageTips) private var showUsageTips

    private var title: String {
        String(localized: "settings.app.showUsageTips", defaultValue: "Show Usage Tips")
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:app:usage-tips",
            title,
            subtitle: showUsageTips
                ? String(localized: "settings.app.showUsageTips.subtitleOn", defaultValue: "Occasionally show a small tip for lesser-known cmux features.")
                : String(localized: "settings.app.showUsageTips.subtitleOff", defaultValue: "Usage tips stay hidden.")
        ) {
            Toggle(isOn: $showUsageTips) {
                EmptyView()
            }
            .labelsHidden()
            .controlSize(.small)
            .focusable(false)
            .accessibilityIdentifier("SettingsShowUsageTipsToggle")
            .accessibilityLabel(title)
        }
    }
}
