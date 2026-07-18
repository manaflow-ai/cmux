#if DEBUG
import SwiftUI

/// Renders the shared settings fixture as a deliberately first-party inset-grouped form.
struct MeridianSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var notificationsEnabled = DesignGalleryFixtures.settings.notificationsEnabled
    @State private var appearance = "System"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(theme.label)
                .padding(.horizontal, theme.horizontalInset)
                .padding(.top, 14)
                .padding(.bottom, 4)

            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: settings.accountEmail)
                }

                Section("Paired Mac") {
                    LabeledContent {
                        Text(settings.pairedMacStatus)
                            .foregroundStyle(theme.done)
                    } label: {
                        Label(settings.pairedMacName, systemImage: "desktopcomputer")
                    }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notifications") {
                    Toggle("Agent activity", isOn: $notificationsEnabled)
                }

                Section("Terminal") {
                    LabeledContent("Font size", value: settings.terminalFontSize)
                }

                Section("About") {
                    LabeledContent("Version", value: settings.appVersion)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.accent)
    }

    private var settings: GallerySettingsFixture {
        DesignGalleryFixtures.settings
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
