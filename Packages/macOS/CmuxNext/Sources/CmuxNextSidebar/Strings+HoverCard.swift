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
    /// A blank browser tab's (about:blank) title in the hover card's tab rows.
    static var hoverCardNewTab: String { String(localized: "sidebar.hoverCard.tab.newTab", defaultValue: "New Tab", bundle: .module) }
    static var hoverCardKindTerminal: String { String(localized: "sidebar.hoverCard.tab.kind.terminal", defaultValue: "Terminal", bundle: .module) }
    static var hoverCardKindRemoteTerminal: String {
        String(localized: "sidebar.hoverCard.tab.kind.remoteTerminal", defaultValue: "Remote terminal", bundle: .module)
    }
    static var hoverCardKindBrowser: String { String(localized: "sidebar.hoverCard.tab.kind.browser", defaultValue: "Browser", bundle: .module) }
    static var hoverCardKindAgentChat: String { String(localized: "sidebar.hoverCard.tab.kind.agentChat", defaultValue: "Agent chat", bundle: .module) }
    static var hoverCardKindTab: String { String(localized: "sidebar.hoverCard.tab.kind.tab", defaultValue: "Tab", bundle: .module) }
    /// The tab list's kind groups (a gallery variant).
    static var hoverCardGroupTerminals: String { String(localized: "sidebar.hoverCard.tab.group.terminals", defaultValue: "Terminals", bundle: .module) }
    static var hoverCardGroupAgents: String { String(localized: "sidebar.hoverCard.tab.group.agents", defaultValue: "Agents", bundle: .module) }
    static var hoverCardGroupPages: String { String(localized: "sidebar.hoverCard.tab.group.pages", defaultValue: "Pages", bundle: .module) }
    static var hoverCardGroupOther: String { String(localized: "sidebar.hoverCard.tab.group.other", defaultValue: "Other", bundle: .module) }
    /// The summary header's running count ("2 running").
    static func hoverCardRunning(_ value: Int) -> String {
        String(localized: "sidebar.hoverCard.tab.running", defaultValue: "\(value) running", bundle: .module)
    }
}
