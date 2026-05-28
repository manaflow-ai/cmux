import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Import Browser Data** section.
///
/// The actual browser-import flow (Safari / Chrome / etc. for bookmarks,
/// history, and cookies) is a UI workflow in the existing app driven by
/// `Sources/Browser/` controllers; it is not a settings-storage concern.
/// This section exposes the persistent toggles that *are* settings —
/// today, just whether the blank-tab import hint is shown — and links
/// to the import workflow.
public struct BrowserImportSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Import hint") {
                SettingsToggleRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.browser.showImportHintOnBlankTabs
                    ),
                    title: "Show import hint on blank tabs",
                    subtitle: "When a new tab opens, suggest importing bookmarks from your previous browser."
                )
            }
            Section {
                Text("The actual import flow (Safari, Chrome, etc. for bookmarks, history, and cookies) is initiated from the browser UI, not from settings. Open a blank tab to see the import shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Importing data")
            }
        }
        .formStyle(.grouped)
    }
}
