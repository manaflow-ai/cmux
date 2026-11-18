import Foundation

extension Strings {
    static var hoverCloud: String { String(localized: "sidebar.hoverCard.cloud", defaultValue: "Cloud", bundle: .l10n) }
    /// The ✕ on a hover preview tab row, for VoiceOver.
    static var hoverCardCloseTab: String { String(localized: "sidebar.hoverCard.closeTab", defaultValue: "Close tab", bundle: .l10n) }
    static var showDetails: String { String(localized: "sidebar.hoverCard.showDetails", defaultValue: "Show details", bundle: .l10n) }
    static var hideDetails: String { String(localized: "sidebar.hoverCard.hideDetails", defaultValue: "Hide details", bundle: .l10n) }
    /// "3 subagents": an agent chat's running subagents (`WorkspaceHoverCardWork`).
    static func subagentsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.subagents.one", defaultValue: "1 subagent", bundle: .l10n)
            : String(format: String(localized: "sidebar.hoverCard.subagents.other", defaultValue: "%d subagents", bundle: .l10n), count)
    }
    /// "2 commands": an agent chat's running background commands.
    static func commandsRunning(_ count: Int) -> String {
        count == 1 ? String(localized: "sidebar.hoverCard.commands.one", defaultValue: "1 command", bundle: .l10n)
            : String(format: String(localized: "sidebar.hoverCard.commands.other", defaultValue: "%d commands", bundle: .l10n), count)
    }
    /// A blank browser tab's (about:blank) title in the hover card's tab rows.
    static var hoverCardNewTab: String { String(localized: "sidebar.hoverCard.tab.newTab", defaultValue: "New Tab", bundle: .l10n) }
    static var hoverCardKindTerminal: String { String(localized: "sidebar.hoverCard.tab.kind.terminal", defaultValue: "Terminal", bundle: .l10n) }
    static var hoverCardKindRemoteTerminal: String {
        String(localized: "sidebar.hoverCard.tab.kind.remoteTerminal", defaultValue: "Remote terminal", bundle: .l10n)
    }
    static var hoverCardKindBrowser: String { String(localized: "sidebar.hoverCard.tab.kind.browser", defaultValue: "Browser", bundle: .l10n) }
    static var hoverCardKindAgentChat: String { String(localized: "sidebar.hoverCard.tab.kind.agentChat", defaultValue: "Agent chat", bundle: .l10n) }
    /// Where a tab of this Mac runs, in the hover card's tab rows.
    static var hoverCardThisMac: String { String(localized: "sidebar.hoverCard.tab.thisMac", defaultValue: "This Mac", bundle: .l10n) }
    static var hoverCardKindTab: String { String(localized: "sidebar.hoverCard.tab.kind.tab", defaultValue: "Tab", bundle: .l10n) }
    /// The tab list's kind groups (a gallery variant).
    static var hoverCardGroupTerminals: String { String(localized: "sidebar.hoverCard.tab.group.terminals", defaultValue: "Terminals", bundle: .l10n) }
    static var hoverCardGroupAgents: String { String(localized: "sidebar.hoverCard.tab.group.agents", defaultValue: "Agents", bundle: .l10n) }
    static var hoverCardGroupPages: String { String(localized: "sidebar.hoverCard.tab.group.pages", defaultValue: "Pages", bundle: .l10n) }
    static var hoverCardGroupOther: String { String(localized: "sidebar.hoverCard.tab.group.other", defaultValue: "Other", bundle: .l10n) }
    /// The summary header's running count ("2 running").
    static func hoverCardRunning(_ value: Int) -> String {
        String(localized: "sidebar.hoverCard.tab.running", defaultValue: "\(value) running", bundle: .l10n)
    }
}
