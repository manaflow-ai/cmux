import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Import browser data and control the import hint on blank tabs.
@MainActor
public struct BrowserImportSection: View {
    private let hostActions: SettingsHostActions
    @State private var importHint: DefaultsValueModel<Bool>

    /// Creates the import page using the shared settings store and host actions.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _importHint = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.showImportHintOnBlankTabs))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(SettingsSectionID.browserImport.title, section: .browserImport)
            SettingsCard { importCard }
        }
        .task { startSettingsObservation([importHint]) }
    }

    @ViewBuilder
    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                        .cmuxFont(size: 12.5, weight: .semibold)
                    Text(String(localized: "browser.import.hint.subtitle", defaultValue: "Import bookmarks, history, and cookies from Safari, Chrome, Firefox, Brave, Edge, or Arc. Already-imported entries are deduped automatically."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SettingsBrowserImportSummary")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                )
            }
            HStack(spacing: 8) {
                Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) { hostActions.openBrowserImportFlow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserImportChooseButton")
                Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            }
            .accessibilityIdentifier("SettingsBrowserImportActions")
            .settingsSearchAnchors(["setting:browserImport:import-data"])
            Toggle(
                String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"),
                isOn: Binding(get: { importHint.current }, set: { importHint.set($0) })
            )
            .controlSize(.small)
            .accessibilityIdentifier("SettingsBrowserImportHintToggle")
            .settingsSearchAnchors(["setting:browserImport:import-hint"])
            Text(String(localized: "settings.browser.import.hint.settingsNote", defaultValue: "Shown until you import or dismiss it on a blank tab."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("SettingsBrowserImportSection")
    }

}
