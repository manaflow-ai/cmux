import CmuxSettings
import SwiftUI

/// **Import Browser Data** section.
@MainActor
public struct BrowserImportSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Import Browser Data")

            if let hostActions {
                SettingsCard {
                    SettingsCardRow(
                        configurationReview: .action,
                        "Import from Another Browser",
                        subtitle: "Launches the source picker (Safari, Chrome, Firefox, Brave, Edge, Arc) and the profile + cookie prompts."
                    ) {
                        Button("Import…") { hostActions.openBrowserImportFlow() }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSectionHeader("Import Hint")
            SettingsCard {
                toggleRow("Show Import Hint on Blank Tabs",
                    subtitle: "When a new tab opens, suggest importing bookmarks from your previous browser.",
                    json: "browser.showImportHintOnBlankTabs",
                    key: catalog.browser.showImportHintOnBlankTabs)
                SettingsCardDivider()
                toggleRow("Import Hint Dismissed",
                    subtitle: "Tracks whether the user has dismissed the hint. Toggle off to surface it again.",
                    json: "browser.importHintDismissed",
                    key: catalog.browser.importHintDismissed)
                SettingsCardDivider()
                textRow("Import Hint Variant",
                    subtitle: "Visual variant of the blank-tab hint.",
                    placeholder: "compact | expanded | banner",
                    json: "browser.importHintVariant",
                    key: catalog.browser.importHintVariant)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func textRow(_ title: String, subtitle: String?, placeholder: String, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 200) {
            TextField(placeholder, text: Binding(get: { model.current }, set: { model.set($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }
}
