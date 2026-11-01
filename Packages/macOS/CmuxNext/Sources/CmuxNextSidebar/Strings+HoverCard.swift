import Foundation

extension Strings {
    static var hoverCloud: String { String(localized: "sidebar.hoverCard.cloud", defaultValue: "Cloud", bundle: .module) }
    static var showDetails: String { String(localized: "sidebar.hoverCard.showDetails", defaultValue: "Show details", bundle: .module) }
    static var hideDetails: String { String(localized: "sidebar.hoverCard.hideDetails", defaultValue: "Hide details", bundle: .module) }
    /// "3 subagents": an agent chat's running subagents (`WorkspaceHoverCardWork`).
    static func subagentsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.subagents.one", defaultValue: "1 subagent", bundle: .module)
            : String(format: String(localized: "sidebar.hoverCard.subagents.other", defaultValue: "%d subagents", bundle: .module), count)
    }
    /// "2 commands": an agent chat's running background commands.
    static func commandsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.commands.one", defaultValue: "1 command", bundle: .module)
            : String(format: String(localized: "sidebar.hoverCard.commands.other", defaultValue: "%d commands", bundle: .module), count)
    }
}
