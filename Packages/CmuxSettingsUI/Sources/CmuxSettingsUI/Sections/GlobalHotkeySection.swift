import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Global Hotkey** section.
///
/// The global hotkey is the system-wide keyboard shortcut that toggles
/// cmux visibility from any application. cmux's AppKit hotkey
/// controller reads this enabled flag and the shortcut chord from the
/// keyboard-shortcut settings store; this view exposes the enable
/// toggle and points at the recorder in the Keyboard Shortcuts pane
/// for the actual chord.
@MainActor
public struct GlobalHotkeySection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("System-Wide Hotkey") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.app.systemWideHotkeyEnabled),
                    title: "Enable System-Wide Hotkey",
                    subtitle: "When enabled, the configured chord toggles cmux's visibility from any application."
                )
            }
            Section {
                Text("The chord is configured in **Keyboard Shortcuts → Global → Toggle cmux**. Recording the chord requires Accessibility permission for cmux.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Configuring the chord")
            }
        }
        .formStyle(.grouped)
    }
}
