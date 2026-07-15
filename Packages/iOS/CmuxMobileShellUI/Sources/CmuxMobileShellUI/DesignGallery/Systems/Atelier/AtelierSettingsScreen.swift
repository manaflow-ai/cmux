#if DEBUG
import SwiftUI

/// Shows shared account and preference fixtures in four roomy card groups.
struct AtelierSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearance = "System"
    @State private var notificationsEnabled = DesignGalleryFixtures.settings.notificationsEnabled

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)
        let settings = DesignGalleryFixtures.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.textPrimary)

                AtelierSettingsGroup(title: "Account") {
                    AtelierSettingsRow(label: "Email", value: settings.accountEmail, symbol: "person.crop.circle")
                    Divider().overlay(theme.hairline)
                    AtelierSettingsRow(label: "Version", value: settings.appVersion, symbol: "info.circle")
                }

                AtelierSettingsGroup(title: "Paired Mac") {
                    AtelierSettingsRow(label: settings.pairedMacName, value: settings.pairedMacStatus, symbol: "laptopcomputer")
                }

                AtelierSettingsGroup(title: "Appearance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color scheme")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.textPrimary)
                        Picker("Color scheme", selection: $appearance) {
                            Text("Light").tag("Light")
                            Text("System").tag("System")
                            Text("Dark").tag("Dark")
                        }
                        .pickerStyle(.segmented)
                    }
                    .frame(minHeight: 72)
                    Divider().overlay(theme.hairline)
                    AtelierSettingsRow(label: "Terminal font", value: "\(settings.terminalFontSize) pt", symbol: "textformat.size")
                }

                AtelierSettingsGroup(title: "Notifications") {
                    Toggle(isOn: $notificationsEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "bell")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Agent updates")
                                    .font(.system(size: 16))
                                    .foregroundStyle(theme.textPrimary)
                                Text(notificationsEnabled ? "On" : "Off")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .frame(minHeight: 56)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
    }
}
#endif
