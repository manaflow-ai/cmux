import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the opt-in sidebar agent-usage row
    /// (`sidebar.showAgentUsage`), appended to ``cmuxDefault(catalog:)``.
    static var sidebarAgentUsageEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .sidebarAppearance,
                id: "show-agent-usage",
                title: String(localized: "settings.app.showAgentUsage", defaultValue: "Show Agent Usage in Sidebar"),
                detailText: String(localized: "settings.app.showAgentUsage.subtitle", defaultValue: "Append the model, context window used, and estimated API cost to Claude Code and Codex status entries. Cost is an estimate from published API prices, not a bill."),
                paths: ["sidebar.showAgentUsage"],
                synonyms: "sidebar.showAgentUsage agent usage model context window tokens percent cost price estimate spend claude codex"
            ),
        ]
    }
}
