import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// Appearance: the theme is Ghostty's; show its colors.
struct ThemeCard: View {
    var body: some View {
        SettingsCard(title: SettingsWindowStrings.themeTitle) {
            HStack(spacing: Metrics.space5) {
                HStack(spacing: Metrics.space1) {
                    ForEach(Array(ThemeStore.shared.input.palette.prefix(8).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: Metrics.space1, style: .continuous)
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                    }
                }
                Text(SettingsWindowStrings.themeBody).foregroundStyle(SettingsStyle.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space5)
            .frame(minHeight: SettingsStyle.rowHeight)
        }
    }
}

struct TerminalInfoCard: View {
    let model: SettingsWindowModel

    var body: some View {
        SettingsCard(title: nil) {
            Text(SettingsWindowStrings.terminalBody).foregroundStyle(SettingsStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
                .padding(.horizontal, Metrics.space5)
            InfoRow(title: SettingsWindowStrings.ghosttyConfig, value: model.host?.ghosttyConfigPath ?? "")
            InfoRow(title: SettingsWindowStrings.shellIntegration,
                    value: model.host?.shellIntegration ?? SettingsWindowStrings.shellIntegrationUnknown)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: Metrics.space6)
            Text(value).foregroundStyle(SettingsStyle.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Metrics.space5)
        .frame(minHeight: SettingsStyle.rowHeight)
    }
}
