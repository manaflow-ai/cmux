import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Beta Features** section.
///
/// Each beta feature is one labeled `SettingsToggleRow` backed by a
/// catalog key under `BetaFeaturesCatalogSection`. The opening note is
/// the user-facing reminder that these flags are unstable and may
/// change or break.
public struct BetaFeaturesSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section {
                Text("Beta features are unstable, may change without notice, and are subject to break. Enable at your own risk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Right Sidebar") {
                SettingsToggleRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.betaFeatures.rightSidebarDock
                    ),
                    title: "Dock",
                    subtitle: "Show the experimental right-sidebar Dock with terminal controls. Replaces the per-pane chrome with a unified rail."
                )
            }
        }
        .formStyle(.grouped)
    }
}
