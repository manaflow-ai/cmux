import CmuxSettings
import SwiftUI

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
            configurationReview: .json("terminal.autoResumeAgentSessions"),
            String(
                localized: "settings.terminal.agentAutoResume",
                defaultValue: "Resume Agent Sessions on Reopen"
            ),
            subtitle: model.autoResume.current
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
                get: { model.autoResume.current },
                set: { model.setAutoResume($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.deferAgentResumeUntilFirstFocus"),
            String(
                localized: "settings.terminal.agentDeferResumeUntilFirstFocus",
                defaultValue: "Resume Agents on First Focus"
            ),
            subtitle: model.deferResumeUntilFirstFocus.current
                ? String(
                    localized: "settings.terminal.agentDeferResumeUntilFirstFocus.subtitleOn",
                    defaultValue: "Restored agent terminals wait until you focus or view their tab before running their resume command, so opening many sessions at once doesn't launch them all immediately."
                )
                : String(
                    localized: "settings.terminal.agentDeferResumeUntilFirstFocus.subtitleOff",
                    defaultValue: "Restored agent terminals run their resume command immediately, even for tabs you haven't looked at yet."
                )
        ) {
            Toggle("", isOn: Binding(
                get: { model.deferResumeUntilFirstFocus.current },
                set: { model.setDeferResumeUntilFirstFocus($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .disabled(!model.autoResume.current)
            .accessibilityIdentifier("SettingsTerminalAgentDeferResumeToggle")
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("terminal.autoRetryAgentSessions"),
            String(
                localized: "settings.terminal.agentAutoRetry",
                defaultValue: "Retry Failed Agent Sessions"
            ),
            subtitle: model.autoRetry.current
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
                get: { model.autoRetry.current },
                set: { model.setAutoRetry($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAgentAutoRetryToggle")
        }
        .task {
            model.startObserving()
        }
    }
}
