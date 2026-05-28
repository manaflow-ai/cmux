import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Terminal** section.
///
/// Hosts scrollbar visibility, copy-on-select, agent session resume/
/// hibernation, and the multi-line text-box maximum height.
public struct TerminalSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Display") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar),
                    title: "Show terminal scroll bar"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect),
                    title: "Copy on selection",
                    subtitle: "Selecting text in a terminal copies it to the clipboard automatically."
                )
                SettingsStepperRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines),
                    title: "Text box max lines",
                    range: 1...20
                )
            }
            Section("Agents") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions),
                    title: "Resume agent sessions on reopen",
                    subtitle: "When cmux relaunches, restore Claude / Codex / opencode sessions automatically."
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled),
                    title: "Hibernate idle agents",
                    subtitle: "Suspend background agent terminals after a period of inactivity."
                )
                SettingsStepperRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals),
                    title: "Max live agent terminals",
                    range: 1...256
                )
            }
        }
        .formStyle(.grouped)
    }
}
