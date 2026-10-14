/// The agent panes a chat opened for its subagents (`chat.subagentPane`): each subagent's tab, so a
/// second request shows the open pane instead of a second one, and the pane the next one stacks
/// under. The first subagent's pane opens right of the chat; each later one opens below the newest
/// pane still open, so the chat keeps its width and one column holds them all.
///
/// A subagent pane is a tab on the chat's own acpmux session that shows the subagent's view: it
/// stays a whole chat tab, so closing the chat leaves it working on the same session.
@MainActor
public final class AgentSubagentPanes {
    private var tabs: [String: String] = [:]
    private var order: [String] = []

    public init() {}

    /// The open tab of subagent `agent`; `isOpen` says whether a tab key still exists.
    public func tab(for agent: String, isOpen: (String) -> Bool) -> String? {
        prune(isOpen)
        return tabs[agent]
    }

    /// The tab a new subagent pane stacks under: the newest open one, or nil for none.
    public func stackAnchor(isOpen: (String) -> Bool) -> String? {
        prune(isOpen)
        return order.last
    }

    /// Records the tab that shows subagent `agent`.
    public func record(_ agent: String, tab key: String) {
        tabs[agent] = key
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Rekeys a provisional tab to the store's id.
    public func rekey(_ old: String, to new: String) {
        for (agent, key) in tabs where key == old { tabs[agent] = new }
        order = order.map { $0 == old ? new : $0 }
    }

    private func prune(_ isOpen: (String) -> Bool) {
        tabs = tabs.filter { isOpen($0.value) }
        order.removeAll { !isOpen($0) }
    }

    /// The `revealTurn` value that opens a pane on subagent `agent`'s view (the page's
    /// `SUBAGENT_REVEAL`).
    public static func reveal(_ agent: String) -> String { "subagent:\(agent)" }
}
