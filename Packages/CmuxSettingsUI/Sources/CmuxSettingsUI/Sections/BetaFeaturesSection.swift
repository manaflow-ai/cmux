import CmuxSettings
import SwiftUI

/// **Beta Features** section: a warning note followed by the master
/// `Dock` toggle (gates the multi-dock workspace layout) and a nested
/// `Left Dock` toggle that is enabled only while `Dock` is on.
@MainActor
public struct BetaFeaturesSection: View {
    @State private var dock: DefaultsValueModel<Bool>
    @State private var leftDock: DefaultsValueModel<Bool>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _dock = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.dock))
        _leftDock = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.leftDock))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features"), section: .betaFeatures)
            SettingsCard {
                BetaFeaturesWarningNote(
                    String(localized: "settings.betaFeatures.warning", defaultValue: "Dock is unstable and may change or break. Enable it only when you are testing it.")
                )
                SettingsCardDivider()
                dockRow
                SettingsCardDivider()
                leftDockRow
            }
        }
    }

    @ViewBuilder
    private var dockRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:dock",
            String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"),
            subtitle: dock.current
                ? String(localized: "settings.betaFeatures.dock.subtitleOn", defaultValue: "Shows dock toggles in the workspace titlebar. Each edge dock has its own split tree.")
                : String(localized: "settings.betaFeatures.dock.subtitleOff", defaultValue: "Adds bottom and right docks to the workspace titlebar. Enable to try the multi-dock layout.")
        ) {
            Toggle("", isOn: Binding(get: { dock.current }, set: { dock.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaDockToggle")
        }
    }

    @ViewBuilder
    private var leftDockRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:leftDock",
            String(localized: "settings.betaFeatures.leftDock", defaultValue: "Left Dock"),
            subtitle: leftDock.current
                ? String(localized: "settings.betaFeatures.leftDock.subtitleOn", defaultValue: "Shows the left dock toggle in the workspace titlebar.")
                : String(localized: "settings.betaFeatures.leftDock.subtitleOff", defaultValue: "Hides the left dock toggle until you enable it here. Bottom and right docks stay available.")
        ) {
            Toggle("", isOn: Binding(get: { leftDock.current }, set: { leftDock.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .disabled(!dock.current)
                .accessibilityIdentifier("SettingsBetaLeftDockToggle")
        }
        .opacity(dock.current ? 1 : 0.5)
    }
}

/// Small warning callout with a yellow triangle, used at the top of
/// the Beta Features card to remind users the toggles below are
/// unstable. Mirrors the legacy `BetaFeaturesWarningNote`.
@MainActor
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
