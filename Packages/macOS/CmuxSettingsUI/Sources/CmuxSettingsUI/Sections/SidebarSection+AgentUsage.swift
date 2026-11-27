import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The opt-in `sidebar.showAgentUsage` toggle row. Usage renders inside
    /// the custom metadata rows, so it is disabled while "Hide All Details"
    /// is on or custom metadata is off.
    @ViewBuilder
    var agentUsageRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.showAgentUsage"),
            String(localized: "settings.app.showAgentUsage", defaultValue: "Show Agent Usage in Sidebar"),
            subtitle: String(localized: "settings.app.showAgentUsage.subtitle", defaultValue: "Append the model and context window used to Claude Code and Codex status entries, plus an estimated API cost for Claude Code. The cost is an API list-price estimate, not your subscription bill.")
        ) {
            Toggle("", isOn: Binding(get: { showAgentUsage.current }, set: { showAgentUsage.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current || !showMetadata.current)
        SettingsCardDivider()
    }
}
