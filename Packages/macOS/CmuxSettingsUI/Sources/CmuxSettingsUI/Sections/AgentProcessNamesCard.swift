import CmuxFoundation
import SwiftUI

/// Settings card for naming agent processes after the agent in Activity Monitor.
@MainActor
struct AgentProcessNamesCard: View {
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.agentProcessNames"),
                String(localized: "settings.automation.agentProcessNames", defaultValue: "Name Agent Processes", bundle: .module),
                subtitle: isEnabled
                    ? String(localized: "settings.automation.agentProcessNames.subtitleOn", defaultValue: "Activity Monitor shows Claude Code as claude.", bundle: .module)
                    : String(localized: "settings.automation.agentProcessNames.subtitleOff", defaultValue: "Activity Monitor shows Claude Code by its version number.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { isEnabled }, set: setEnabled))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentProcessNamesToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(
                localized: "settings.automation.agentProcessNames.note",
                defaultValue: "Claude Code installs each version as a file named after its version number, and macOS names a process after that file. cmux starts Claude from a hardlink named claude in its cache folder instead, which uses no extra disk space. Applies to agents started after the change.",
                bundle: .module
            ))
        }
    }
}
