import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Import Browser Data** section.
///
/// The actual browser-import workflow (Safari / Chrome / Firefox source
/// pickers, profile selection, the cookie-prompt UI) is a multi-step
/// flow in the host app driven by `Sources/Browser/` controllers; it is
/// not a settings-storage concern. This section exposes the persistent
/// toggles that *are* settings and explains where the flow lives.
@MainActor
public struct BrowserImportSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Import Hint") {
                SettingsToggleRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.browser.showImportHintOnBlankTabs
                    ),
                    title: "Show Import Hint on Blank Tabs",
                    subtitle: "When a new tab opens, suggest importing bookmarks and history from your previous browser."
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.browser.importHintDismissed
                    ),
                    title: "Import Hint Dismissed",
                    subtitle: "Tracks whether the user has dismissed the hint. Toggle off to surface the hint again."
                )
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.browser.importHintVariant
                    ),
                    title: "Import Hint Variant",
                    placeholder: "compact | expanded | banner",
                    subtitle: "Visual variant of the blank-tab hint."
                )
            }
            Section {
                Text("The actual import flow (Safari, Chrome, Firefox for bookmarks, history, and cookies) is launched from the blank-tab hint or from the Browser menu. Open a blank tab to see the import shortcut, or use Browser → Import…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Running the import")
            }
        }
        .formStyle(.grouped)
    }
}
