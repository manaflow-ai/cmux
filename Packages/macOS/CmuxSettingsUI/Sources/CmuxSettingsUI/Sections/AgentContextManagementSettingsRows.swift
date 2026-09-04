import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings rows for opt-in terminal-side managed-agent context recovery.
@MainActor
struct AgentContextManagementSettingsRows: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var action: DefaultsValueModel<String>
    @State private var preserveState: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.agentContextManagementEnabled
        ))
        _action = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.agentContextManagementAction
        ))
        _preserveState = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.agentContextManagementPreserveState
        ))
    }

    var body: some View {
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.agentContextManagement.enabled"),
            String(localized: "settings.terminal.agentContextManagement", defaultValue: "Manage Agent Context Pressure"),
            subtitle: enabled.current
                ? String(localized: "settings.terminal.agentContextManagement.subtitleOn", defaultValue: "When Claude Code or Codex reports pressure at a proven idle prompt, cmux can send the selected recovery command.")
                : String(localized: "settings.terminal.agentContextManagement.subtitleOff", defaultValue: "cmux reports pressure but never writes recovery commands into agent terminals while this is off."),
            controlWidth: 230
        ) {
            Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalAgentContextManagementToggle")
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.agentContextManagement.action"),
            String(localized: "settings.terminal.agentContextManagement.action", defaultValue: "Recovery Command"),
            subtitle: String(localized: "settings.terminal.agentContextManagement.action.subtitle", defaultValue: "Choose whether cmux sends /compact or starts a fresh context with /clear."),
            controlWidth: 180
        ) {
            Picker("", selection: Binding(get: { action.current }, set: { action.set($0) })) {
                Text(String(localized: "settings.terminal.agentContextManagement.action.compact", defaultValue: "/compact")).tag("compact")
                Text(String(localized: "settings.terminal.agentContextManagement.action.clear", defaultValue: "Fresh context")).tag("clear")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(!enabled.current)
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.agentContextManagement.preserveState"),
            String(localized: "settings.terminal.agentContextManagement.preserveState", defaultValue: "Preserve State Before Fresh Context"),
            subtitle: String(localized: "settings.terminal.agentContextManagement.preserveState.subtitle", defaultValue: "Ask the agent for a brief handoff note and wait for acknowledgement before starting a fresh context."),
            controlWidth: 230
        ) {
            Toggle("", isOn: Binding(get: { preserveState.current }, set: { preserveState.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .disabled(!(enabled.current && action.current == "clear"))
                .accessibilityIdentifier("SettingsTerminalAgentContextManagementPreserveStateToggle")
        }
        SettingsCardDivider()
            .task { startObserving() }
    }

    private func startObserving() {
        enabled.startObserving()
        action.startObserving()
        preserveState.startObserving()
    }
}
