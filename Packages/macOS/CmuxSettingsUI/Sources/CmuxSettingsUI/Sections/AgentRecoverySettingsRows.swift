import CmuxSettings
import SwiftUI

/// Settings rows for managed-agent recovery behavior.
@MainActor
struct AgentRecoverySettingsRows: View {
    @State private var model: AgentRecoverySettingsModel

    init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: any SettingsHostActions
    ) {
        _model = State(initialValue: AgentRecoverySettingsModel(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions
        ))
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.autoRetryAgentSessions"),
            String(
                localized: "settings.terminal.agentAutoRetry",
                defaultValue: "Retry Stalled Agent Sessions"
            ),
            subtitle: model.isAutoRetryEnabled
                ? String(
                    localized: "settings.terminal.agentAutoRetry.subtitleOn",
                    defaultValue: "Transient API failures at an idle agent prompt retry automatically with bounded backoff. Safeguards, quota, and auth failures always require you."
                )
                : String(
                    localized: "settings.terminal.agentAutoRetry.subtitleOff",
                    defaultValue: "Stalled agent sessions stay idle until you resume them manually."
                )
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.isAutoRetryEnabled },
                    set: { model.setAutoRetryEnabled($0) }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAgentAutoRetryToggle")
        }
        .task { model.startObserving() }
    }
}
