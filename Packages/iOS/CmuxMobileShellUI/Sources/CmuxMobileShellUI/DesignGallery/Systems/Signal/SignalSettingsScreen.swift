#if DEBUG
import SwiftUI

/// Renders fixture preferences as a sectioned Signal table with a teaching legend.
struct SignalSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var notificationsEnabled = DesignGalleryFixtures.settings.notificationsEnabled

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)
        let fixture = DesignGalleryFixtures.settings
        let statuses = [
            GalleryAgentState.needsYou,
            GalleryAgentState.failed,
            GalleryAgentState.running,
            GalleryAgentState.done,
            GalleryAgentState.idle,
        ]

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Account", color: theme.secondaryText)
                    VStack(spacing: 0) {
                        SignalSettingsValueRow(label: "Email", value: fixture.accountEmail, theme: theme)
                        SignalSettingsValueRow(label: "Version", value: fixture.appVersion, theme: theme)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Paired Mac", color: theme.secondaryText)
                    VStack(spacing: 0) {
                        SignalSettingsValueRow(label: "Device", value: fixture.pairedMacName, theme: theme)
                        SignalSettingsValueRow(label: "Status", value: fixture.pairedMacStatus, theme: theme)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Appearance", color: theme.secondaryText)
                    SignalSettingsValueRow(
                        label: "Mode",
                        value: colorScheme == .dark ? "DARK" : "LIGHT",
                        theme: theme
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Preferences", color: theme.secondaryText)
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("Notifications")
                                .font(.system(.subheadline, design: .default, weight: .regular))
                                .foregroundStyle(theme.ink)
                            Spacer()
                            SignalToggleButton(isOn: $notificationsEnabled, theme: theme)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 56)
                        .background(theme.surface)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(theme.hairline)
                                .frame(height: 1)
                        }

                        SignalSettingsValueRow(
                            label: "Terminal font size",
                            value: fixture.terminalFontSize,
                            theme: theme
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Legend", color: theme.secondaryText)
                    VStack(spacing: 0) {
                        ForEach(Array(statuses.enumerated()), id: \.offset) { _, state in
                            SignalStatusMeaningRow(
                                style: SignalStatusStyle(state: state, theme: theme),
                                theme: theme
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignalTriageBar(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
