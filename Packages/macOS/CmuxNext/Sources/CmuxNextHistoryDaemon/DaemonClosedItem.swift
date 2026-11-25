public import CmuxNextDaemon
public import CmuxNextHistory

/// How a daemon closed item reads in History and Recently Closed: its kind, its agent chat, its
/// shown tab and text, and whether it is worth reopening. Pure; the App names it with its pages.
public enum DaemonClosedItem {
    public static func closedKind(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextHistory.ClosedItem.Kind {
        switch item.kind {
        case .tab:
            switch shownTab(item)?.kind {
            case "conversation": .conversationTab
            case "browser": .browserTab
            default: .terminalTab
            }
        case .screen: .screen
        case .workspace, .window: .workspace
        }
    }

    /// A closed tab can be an agent chat. A screen or workspace remains its container kind,
    /// even when the first tab it would reopen is an agent chat.
    public static func closedAgentSession(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextHistory.ClosedItem.AgentSession? {
        guard item.kind == .tab, let agent = shownTab(item)?.agentSession else { return nil }
        return .init(sessionID: agent.session, harness: agent.harness)
    }

    /// Whether reopening `item` gives something back (Leo 2026-10-11: Recently Closed was full of
    /// "workspace-35 about:blank" rows). A group or a window always does; a tab, screen or
    /// workspace only with a tab that is not ``isBlank(_:)``.
    public static func isWorthReopening(_ item: CmuxNextDaemon.ClosedItem) -> Bool {
        item.group != nil || item.kind == .window || item.tabs.contains { !isBlank($0) }
    }

    /// An untouched New Tab page or a browser on `about:blank`, as the daemon marks it (`empty`).
    /// A closed chat with no title yet or a remote terminal looks the same otherwise, and reopens.
    public static func isBlank(_ tab: CmuxNextDaemon.ClosedItem.Tab) -> Bool { tab.empty }

    /// A closed name or address worth showing: a chat or New Tab page is kept as a browser tab on
    /// `about:blank` (a tab item carries that as its name too), never a name or an address.
    public static func realText(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty || $0 == "about:blank" ? nil : $0 }
    }

    /// The tab an item is named by: its first real one, past any New Tab page beside it.
    public static func shownTab(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextDaemon.ClosedItem.Tab? {
        item.tabs.first { !isBlank($0) } ?? item.tabs.first
    }
}
