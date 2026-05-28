import CmuxSettings
import SwiftUI

/// **Global Hotkey** section.
@MainActor
public struct GlobalHotkeySection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Global Hotkey")
            SettingsCard {
                let model = DefaultsValueModel(store: defaultsStore, key: catalog.app.systemWideHotkeyEnabled)
                SettingsCardRow(
                    configurationReview: .json("app.systemWideHotkeyEnabled"),
                    "Enable System-Wide Hotkey",
                    subtitle: "When enabled, the configured chord toggles cmux's visibility from any application."
                ) {
                    Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            SettingsCard {
                SettingsCardRow(configurationReview: .action, "Configuring the chord",
                    subtitle: "The chord is configured in Keyboard Shortcuts → Toggle cmux. Recording the chord requires Accessibility permission for cmux.") {
                    EmptyView()
                }
            }
        }
    }
}
