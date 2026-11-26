import Foundation

extension Strings {
    static var hoverCloud: String { String(localized: "sidebar.hoverCard.cloud", defaultValue: "Cloud", bundle: .localizedModule) }
    /// The ✕ on a hover preview tab row, for VoiceOver.
    static var hoverCardCloseTab: String { String(localized: "sidebar.hoverCard.closeTab", defaultValue: "Close tab", bundle: .localizedModule) }
    static var showDetails: String { String(localized: "sidebar.hoverCard.showDetails", defaultValue: "Show details", bundle: .localizedModule) }
    static var hideDetails: String { String(localized: "sidebar.hoverCard.hideDetails", defaultValue: "Hide details", bundle: .localizedModule) }
    /// "3 subagents": an agent chat's running subagents (`WorkspaceHoverCardWork`).
    static func subagentsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.subagents.one", defaultValue: "1 subagent", bundle: .localizedModule)
            : String(format: String(localized: "sidebar.hoverCard.subagents.other", defaultValue: "%d subagents", bundle: .localizedModule), count)
    }
    /// "2 commands": an agent chat's running background commands.
    static func commandsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.commands.one", defaultValue: "1 command", bundle: .localizedModule)
            : String(format: String(localized: "sidebar.hoverCard.commands.other", defaultValue: "%d commands", bundle: .localizedModule), count)
    }
    /// "desktop-helper on studio-mac": who made a workspace and where (`WorkspaceHoverCardOrigin`).
    static func originOnHost(_ creator: String, _ host: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.origin.onHost", defaultValue: "%1$@ on %2$@", bundle: .module), creator, host)
    }
    /// "Made by desktop-helper · studio-mac": the one-line byline of a workspace's creator.
    static func originMadeBy(_ creator: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.origin.madeBy", defaultValue: "Made by %@", bundle: .module), creator)
    }
    /// The creator's name for a script that ran in no acpmux session.
    static var originScript: String { String(localized: "sidebar.hoverCard.origin.script", defaultValue: "Script", bundle: .module) }
    /// A blank browser tab's (about:blank) title in the hover card's tab rows.
    static var hoverCardNewTab: String { String(localized: "sidebar.hoverCard.tab.newTab", defaultValue: "New Tab", bundle: .localizedModule) }
    static var hoverCardKindTerminal: String { String(localized: "sidebar.hoverCard.tab.kind.terminal", defaultValue: "Terminal", bundle: .localizedModule) }
    static var hoverCardKindRemoteTerminal: String {
        String(localized: "sidebar.hoverCard.tab.kind.remoteTerminal", defaultValue: "Remote terminal", bundle: .localizedModule)
    }
    static var hoverCardKindBrowser: String { String(localized: "sidebar.hoverCard.tab.kind.browser", defaultValue: "Browser", bundle: .localizedModule) }
    static var hoverCardKindAgentChat: String { String(localized: "sidebar.hoverCard.tab.kind.agentChat", defaultValue: "Agent chat", bundle: .localizedModule) }
    /// Where a tab of this Mac runs, in the hover card's tab rows.
    static var hoverCardThisMac: String { String(localized: "sidebar.hoverCard.tab.thisMac", defaultValue: "This Mac", bundle: .localizedModule) }
    static var hoverCardKindTab: String { String(localized: "sidebar.hoverCard.tab.kind.tab", defaultValue: "Tab", bundle: .localizedModule) }
    /// The tab list's kind groups (a gallery variant).
    static var hoverCardGroupTerminals: String { String(localized: "sidebar.hoverCard.tab.group.terminals", defaultValue: "Terminals", bundle: .localizedModule) }
    static var hoverCardGroupAgents: String { String(localized: "sidebar.hoverCard.tab.group.agents", defaultValue: "Agents", bundle: .localizedModule) }
    static var hoverCardGroupPages: String { String(localized: "sidebar.hoverCard.tab.group.pages", defaultValue: "Pages", bundle: .localizedModule) }
    static var hoverCardGroupOther: String { String(localized: "sidebar.hoverCard.tab.group.other", defaultValue: "Other", bundle: .localizedModule) }
    /// The summary header's running count ("2 running").
    static func hoverCardRunning(_ value: Int) -> String {
        String(localized: "sidebar.hoverCard.tab.running", defaultValue: "\(value) running", bundle: .localizedModule)
    }
}
