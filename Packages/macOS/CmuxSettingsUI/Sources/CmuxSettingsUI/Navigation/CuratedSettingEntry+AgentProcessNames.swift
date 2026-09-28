import Foundation

extension CuratedSettingEntry {
    /// Search entry for the Automation row that names agent processes after
    /// the agent, so "activity monitor" or "process name" finds the row.
    static var agentProcessNamesEntry: CuratedSettingEntry {
        .init(
            section: .automation,
            id: "agent-process-names",
            title: String(localized: "settings.automation.agentProcessNames", defaultValue: "Name Agent Processes", bundle: .module),
            paths: ["automation.agentProcessNames"],
            synonyms: "Name Agent Processes automation.agentProcessNames process name activity monitor ps top claude version number"
        )
    }
}
