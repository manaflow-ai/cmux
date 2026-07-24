import CmuxSettings
import SwiftUI

/// **Agent Accounts** section — the local subrouter daemon integration:
/// the master gate, the sidebar footer switcher toggle, and the daemon
/// endpoint / `sr` binary overrides.
@MainActor
public struct SubrouterSection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var showAccountSwitcher: DefaultsValueModel<Bool>
    @State private var endpoint: DefaultsValueModel<String>
    @State private var commandPath: DefaultsValueModel<String>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.subrouter.enabled))
        _showAccountSwitcher = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showAccountSwitcher))
        _endpoint = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.subrouter.endpoint))
        _commandPath = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.subrouter.commandPath))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.subrouter", defaultValue: "Agent Accounts"),
                section: .subrouter
            )
            SettingsCard {
                SettingsCardNote(
                    String(
                        localized: "settings.subrouter.note",
                        defaultValue: "Integrates with the subrouter daemon (github.com/manaflow-ai/subrouter) to show AI-agent account usage and switch Codex and Claude accounts from cmux. Requires subrouter to be installed; cmux polls it only while its UI is visible."
                    )
                )
                SettingsCardDivider()
                enabledRow
                SettingsCardDivider()
                showAccountSwitcherRow
                SettingsCardDivider()
                endpointRow
                SettingsCardDivider()
                commandPathRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            enabled,
            showAccountSwitcher,
            endpoint,
            commandPath,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var enabledRow: some View {
        SettingsCardRow(
            configurationReview: .json("subrouter.enabled"),
            searchAnchorID: "setting:subrouter:enabled",
            String(localized: "settings.subrouter.enabled", defaultValue: "Enable Subrouter Integration"),
            subtitle: enabled.current
                ? String(localized: "settings.subrouter.enabled.subtitleOn", defaultValue: "Shows the Agents right-sidebar panel and enables cmux subrouter CLI commands.")
                : String(localized: "settings.subrouter.enabled.subtitleOff", defaultValue: "cmux never contacts the subrouter daemon while this is off.")
        ) {
            Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSubrouterEnabledToggle")
        }
    }

    @ViewBuilder
    private var showAccountSwitcherRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showAccountSwitcher"),
            searchAnchorID: "setting:subrouter:show-account-switcher",
            String(localized: "settings.subrouter.showAccountSwitcher", defaultValue: "Show Account Switcher in Sidebar Footer"),
            subtitle: String(localized: "settings.subrouter.showAccountSwitcher.subtitle", defaultValue: "A compact status dot and quick-switch popover in the left sidebar footer.")
        ) {
            Toggle("", isOn: Binding(get: { showAccountSwitcher.current }, set: { showAccountSwitcher.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSubrouterShowAccountSwitcherToggle")
        }
        .disabled(!enabled.current)
    }

    @ViewBuilder
    private var endpointRow: some View {
        SettingsCardRow(
            configurationReview: .json("subrouter.endpoint"),
            searchAnchorID: "setting:subrouter:endpoint",
            String(localized: "settings.subrouter.endpoint", defaultValue: "Daemon Endpoint"),
            subtitle: String(localized: "settings.subrouter.endpoint.subtitle", defaultValue: "Leave empty for the default, http://127.0.0.1:31415.")
        ) {
            TextField(
                String(localized: "settings.subrouter.endpoint.placeholder", defaultValue: "e.g. 127.0.0.1:31415"),
                text: Binding(get: { endpoint.current }, set: { endpoint.set($0) })
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
        }
        .disabled(!enabled.current)
    }

    @ViewBuilder
    private var commandPathRow: some View {
        SettingsCardRow(
            configurationReview: .json("subrouter.commandPath"),
            searchAnchorID: "setting:subrouter:command-path",
            String(localized: "settings.subrouter.commandPath", defaultValue: "sr Binary Path"),
            subtitle: String(localized: "settings.subrouter.commandPath.subtitle", defaultValue: "Custom path to the sr/subrouter CLI used for account switches. Leave empty to use PATH and ~/bin.")
        ) {
            TextField(
                String(localized: "settings.subrouter.commandPath.placeholder", defaultValue: "e.g. ~/bin/subrouter"),
                text: Binding(get: { commandPath.current }, set: { commandPath.set($0) })
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
        }
        .disabled(!enabled.current)
    }
}
