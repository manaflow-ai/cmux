import CmuxSettings
import SwiftUI

/// SwiftUI view for the **App** section of the settings window.
///
/// Hosts the user-facing app behavior toggles: appearance currently. As
/// the catalog grows, additional rows for language, app icon, workspace
/// placement, telemetry, and quit/close-tab confirmations land here.
@MainActor
public struct AppSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Appearance") {
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance),
                    title: "Appearance",
                    label: { mode in
                        switch mode {
                        case .system: return "Follow System"
                        case .light: return "Light"
                        case .dark: return "Dark"
                        }
                    }
                )
            }
        }
        .formStyle(.grouped)
    }
}
