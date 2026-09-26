import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The opt-in `sidebar.showAgentUsage` toggle row. Like the other detail
    /// rows it is disabled while "Hide All Details" is on.
    @ViewBuilder
    var agentUsageRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showAgentUsage"),
            String(localized: "settings.app.showAgentUsage", defaultValue: "Show Agent Usage in Sidebar"),
            subtitle: String(localized: "settings.app.showAgentUsage.subtitle", defaultValue: "Append the model, context window used, and estimated API cost to Claude Code and Codex status entries. Cost is an estimate from published API prices, not a bill.")
        ) {
            Toggle("", isOn: Binding(get: { showAgentUsage.current }, set: { showAgentUsage.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current)
        SettingsCardDivider()
    }
}
