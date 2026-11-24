public import Foundation

/// One of a chat's subagents as the sidebar lists it under the chat's row: acpmux's
/// `recentSubagents` (Claude Code's Agent, Task and Workflow calls, Codex's spawned agents), the way
/// the Claude desktop app's Code tab nests a chat's tasks under it (Leo, 2026-11-19: "for claude
/// there's the font and the nested sessions and whatever").
public nonisolated struct SidebarSubagent: Hashable, Sendable, Identifiable {
    /// Where it stands, as acpmux says it (`recentSubagents[].state`).
    public enum State: String, Hashable, Sendable, CaseIterable {
        case running, done, failed
        /// Cancelled, disconnected, or a foreground one whose turn ended without its end.
        case stopped
    }

    /// acpmux's subagent id (what `chat.subagentPane` opens).
    public var id: String
    /// Its name or task, as acpmux masked and cut it; nil when it gave none.
    public var title: String?
    public var state: State
    /// The subagent that started it; nil for one the chat itself started.
    public var parent: String?
    /// The chat tab whose session it belongs to: a click opens its pane beside that tab.
    public var tab: TabID

    public init(id: String, title: String?, state: State, parent: String? = nil, tab: TabID) {
        self.id = id
        self.title = title
        self.state = state
        self.parent = parent
        self.tab = tab
    }
}

/// A workspace's chats' subagents (`SidebarWorkspace.subagents`): the latest few of each chat, oldest
/// first, and how many there are in all and run now.
public nonisolated struct SidebarSubagents: Hashable, Sendable {
    public var items: [SidebarSubagent]
    /// Every subagent its chats started (acpmux `subagentsSeen`), listed or not.
    public var total: Int
    /// The ones that run now (acpmux `subagentsRunning`), listed or not.
    public var running: Int
    /// The chat tab a press opens when no listed subagent names one (an acpmux too old to list them).
    public var chat: TabID?

    public init(items: [SidebarSubagent], total: Int? = nil, running: Int? = nil, chat: TabID? = nil) {
        self.items = items
        self.total = max(total ?? items.count, items.count)
        self.running = running ?? items.filter { $0.state == .running }.count
        self.chat = chat ?? items.first?.tab
    }

    /// Nothing to draw: no listed subagent and none running.
    public var isEmpty: Bool { items.isEmpty && running == 0 }

    /// These subagents without the ones in `hidden` (a child row that lists them itself): a hidden one that
    /// ran leaves the running and total counts too, so "N more" still counts only what runs here.
    public func excluding(_ hidden: Set<String>) -> SidebarSubagents {
        let kept = items.filter { !hidden.contains($0.id) }
        guard kept.count != items.count else { return self }
        let removed = items.filter { hidden.contains($0.id) }
        let removedRunning = removed.filter { $0.state == .running }.count
        return SidebarSubagents(items: kept, total: max(0, total - removed.count), running: max(0, running - removedRunning), chat: chat)
    }
}
