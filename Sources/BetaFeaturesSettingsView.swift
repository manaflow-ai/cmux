import SwiftUI

struct BetaFeaturesSettingsView: View {
    @Binding var dockEnabled: Bool

    private var dockSubtitle: String {
        if dockEnabled {
            return String(
                localized: "settings.betaFeatures.dock.subtitleOn",
                defaultValue: "Shows Dock in the right sidebar mode switcher for custom terminal controls."
            )
        }
        return String(
            localized: "settings.betaFeatures.dock.subtitleOff",
            defaultValue: "Hides Dock from the right sidebar until you enable it here."
        )
    }

    var body: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features"))
            .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .betaFeatures))
        SettingsCard {
            BetaFeaturesWarningNote(
                String(
                    localized: "settings.betaFeatures.warning",
                    defaultValue: "Dock is unstable and may change or break. Enable it only when you are testing it."
                )
            )

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"),
                subtitle: dockSubtitle,
                searchAnchorID: SettingsSearchIndex.settingID(for: .betaFeatures, idSuffix: "dock")
            ) {
                Toggle("", isOn: $dockEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBetaDockToggle")
                    .accessibilityLabel(
                        String(localized: "settings.betaFeatures.dock", defaultValue: "Dock")
                    )
            }
        }
    }
}

private struct BetaFeaturesWarningNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
