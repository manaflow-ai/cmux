import CmuxSettings
import SwiftUI

@MainActor
struct AgentRecoverySettingsRows: View {
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var autoRetry: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _autoResume = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.autoResumeAgentSessions
        ))
        _autoRetry = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.autoRetryAgentSessions
        ))
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.autoResumeAgentSessions"),
            String(
                localized: "settings.terminal.agentAutoResume",
                defaultValue: "Resume Agent Sessions on Reopen"
            ),
            subtitle: autoResume.current
                ? String(
                    localized: "settings.terminal.agentAutoResume.subtitleOn",
                    defaultValue: "When cmux reopens after quit, restored agent terminals automatically run their resume command."
                )
                : String(
                    localized: "settings.terminal.agentAutoResume.subtitleOff",
                    defaultValue: "When cmux reopens after quit, restored agent terminals stay idle until you resume them manually."
                )
        ) {
            Toggle("", isOn: Binding(
                get: { autoResume.current },
                set: { autoResume.set($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.autoRetryAgentSessions"),
            String(
                localized: "settings.terminal.agentAutoRetry",
                defaultValue: "Retry Failed Agent Sessions"
            ),
            subtitle: autoRetry.current
                ? String(
                    localized: "settings.terminal.agentAutoRetry.subtitleOn",
                    defaultValue: "Agent sessions that exit with an error resume automatically with bounded backoff."
                )
                : String(
                    localized: "settings.terminal.agentAutoRetry.subtitleOff",
                    defaultValue: "Errored agent sessions stay stopped until you resume them manually."
                )
        ) {
            Toggle("", isOn: Binding(
                get: { autoRetry.current },
                set: { autoRetry.set($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAgentAutoRetryToggle")
        }
        .task {
            autoResume.startObserving()
            autoRetry.startObserving()
        }
    }
}
