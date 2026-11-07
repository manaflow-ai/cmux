import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the opt-in sidebar agent-usage row
    /// (`sidebar.showAgentUsage`) and its parts row, appended to
    /// ``cmuxDefault(catalog:)``.
    static var sidebarAgentUsageEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .sidebarAppearance,
                id: "show-agent-usage",
                title: String(localized: "settings.app.showAgentUsage", defaultValue: "Show Agent Usage in Sidebar"),
                detailText: String(localized: "settings.app.showAgentUsage.subtitle", defaultValue: "Append the model and context window used to Claude Code and Codex status entries, plus an estimated API cost for Claude Code. The cost is an API list-price estimate, not your subscription bill."),
                paths: ["sidebar.showAgentUsage"],
                synonyms: "sidebar.showAgentUsage agent usage model context window tokens percent cost price estimate spend claude codex"
            ),
            .init(
                section: .sidebarAppearance,
                id: "agent-usage-parts",
                title: String(localized: "settings.app.agentUsageParts", defaultValue: "Agent Usage Details"),
                paths: ["sidebar.showAgentModel", "sidebar.showAgentContext", "sidebar.showAgentCost"],
                synonyms: "sidebar.showAgentModel sidebar.showAgentContext sidebar.showAgentCost agent usage model context percent cost price hide"
            ),
        ]
    }
}
