import CmuxSettings
import SwiftUI

/// **Beta Features** section.
@MainActor
public struct BetaFeaturesSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Beta Features")

            SettingsCard {
                SettingsCardRow(configurationReview: .action, "About Beta Features",
                    subtitle: "These flags gate unstable, experimental cmux features. They may change or break without notice — enable at your own risk.") {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                }
            }

            SettingsSectionHeader("Right Sidebar")
            SettingsCard {
                let model = DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarDock)
                SettingsCardRow(
                    configurationReview: .json("rightSidebar.beta.dock.enabled"),
                    "Right-Sidebar Dock",
                    subtitle: "Replaces the per-pane action chrome with a unified right-side rail with terminal controls."
                ) {
                    Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        }
    }
}
