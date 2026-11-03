import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The opt-in `sidebar.showAgentUsage` toggle row, then one row of
    /// checkboxes choosing its parts (`sidebar.showAgentModel`,
    /// `sidebar.showAgentContext`, `sidebar.showAgentCost`). Usage renders
    /// inside the custom metadata rows, so both are disabled while "Hide All
    /// Details" is on or custom metadata is off, and the parts row also while
    /// usage is off.
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

        SettingsCardRow(
            configurationReview: .json("sidebar.showAgentModel", "sidebar.showAgentContext", "sidebar.showAgentCost"),
            String(localized: "settings.app.agentUsageParts", defaultValue: "Agent Usage Details")
        ) {
            HStack(spacing: 12) {
                Toggle(
                    String(localized: "settings.app.agentUsageParts.model", defaultValue: "Model"),
                    isOn: Binding(get: { showAgentModel.current }, set: { showAgentModel.set($0) })
                )
                Toggle(
                    String(localized: "settings.app.agentUsageParts.context", defaultValue: "Context"),
                    isOn: Binding(get: { showAgentContext.current }, set: { showAgentContext.set($0) })
                )
                Toggle(
                    String(localized: "settings.app.agentUsageParts.cost", defaultValue: "Cost"),
                    isOn: Binding(get: { showAgentCost.current }, set: { showAgentCost.set($0) })
                )
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .disabled(hideAll.current || !showMetadata.current || !showAgentUsage.current)
        SettingsCardDivider()
    }
}
