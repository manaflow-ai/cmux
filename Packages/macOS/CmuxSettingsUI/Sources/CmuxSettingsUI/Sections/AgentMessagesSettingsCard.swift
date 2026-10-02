import CmuxFoundation
import SwiftUI

/// Settings card for the app-wide agent messages switch
/// (`agentMessages.enabled`).
@MainActor
struct AgentMessagesSettingsCard: View {
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("agentMessages.enabled"),
                String(localized: "settings.automation.agentMessages", defaultValue: "Agent Messages", bundle: .module),
                subtitle: isEnabled
                    ? String(localized: "settings.automation.agentMessages.subtitleOn", defaultValue: "Agents can message each other with cmux agent message.", bundle: .module)
                    : String(localized: "settings.automation.agentMessages.subtitleOff", defaultValue: "Agent messages are off. Sends fail and nothing is delivered.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { isEnabled }, set: setEnabled))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentMessagesToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(
                localized: "settings.automation.agentMessages.note",
                defaultValue: "Turning this off also fails messages that are waiting to be delivered. To turn messages off for one agent, run cmux agent messages off in its terminal.",
                bundle: .module
            ))
        }
    }
}
