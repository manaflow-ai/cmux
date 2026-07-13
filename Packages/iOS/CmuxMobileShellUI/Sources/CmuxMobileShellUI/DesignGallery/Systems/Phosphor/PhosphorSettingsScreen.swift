#if DEBUG
import SwiftUI

/// Re-skins the complete settings fixture as opaque grouped Phosphor controls.
struct PhosphorSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var notificationsEnabled = DesignGalleryFixtures.settings.notificationsEnabled
    @State private var appearanceSelection = 0
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)
        let settings = DesignGalleryFixtures.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionLabel("ACCOUNT", theme: theme)
                PhosphorSettingsRow(
                    symbol: "person.crop.circle",
                    title: "Signed in",
                    value: settings.accountEmail,
                    showsChevron: true
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                sectionLabel("PAIRED MAC", theme: theme)
                VStack(spacing: 0) {
                    PhosphorSettingsRow(
                        symbol: "laptopcomputer",
                        title: "Mac",
                        value: settings.pairedMacName,
                        showsChevron: true
                    )
                    PhosphorSettingsRow(
                        symbol: "checkmark.circle",
                        title: "Connection",
                        value: settings.pairedMacStatus,
                        showsChevron: false
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                sectionLabel("APPEARANCE", theme: theme)
                PhosphorAppearanceControl(selection: $appearanceSelection)

                sectionLabel("PREFERENCES", theme: theme)
                VStack(spacing: 0) {
                    Toggle(isOn: $notificationsEnabled) {
                        Label("Notifications", systemImage: "bell")
                            .font(typography.body)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .tint(theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(theme.bg1)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.hairline).frame(height: 1).padding(.leading, 48)
                    }

                    PhosphorSettingsRow(
                        symbol: "textformat.size",
                        title: "Terminal font",
                        value: settings.terminalFontSize,
                        showsChevron: true
                    )
                    PhosphorSettingsRow(
                        symbol: "info.circle",
                        title: "Version",
                        value: settings.appVersion,
                        showsChevron: false
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg0.ignoresSafeArea())
    }

    private func sectionLabel(_ text: String, theme: PhosphorTheme) -> some View {
        Text(text)
            .font(typography.caption)
            .tracking(0.8)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
            .padding(.bottom, -12)
    }
}
#endif
