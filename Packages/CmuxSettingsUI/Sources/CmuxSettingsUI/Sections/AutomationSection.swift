import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Automation** section.
///
/// Currently exposes the socket control mode (UserDefaults-backed) and
/// the optional socket password (JSON-config-backed, so MDM can
/// preconfigure).
@MainActor
public struct AutomationSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Socket Control") {
                SettingsPickerRow(
                    model: DefaultsValueModel(
                        store: defaultsStore,
                        key: catalog.automation.socketControlMode
                    ),
                    title: "Socket Control Mode",
                    label: { mode in
                        switch mode {
                        case .off: return "Off"
                        case .cmuxOnly: return "Only the bundled cmux CLI"
                        case .automation: return "Automation tools"
                        case .password: return "Password required"
                        case .allowAll: return "Allow all local clients"
                        }
                    }
                )
                SettingsTextFieldRow(
                    model: JSONValueModel(store: jsonStore, key: catalog.automation.socketPassword),
                    title: "Socket Password",
                    placeholder: "Set when 'Password required' is selected"
                )
            }
        }
        .formStyle(.grouped)
    }
}
