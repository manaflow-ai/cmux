/// The agent panes a chat's subagents opened in (`chat.subagentPane`), one tracker per acpmux
/// session, so every pane on that session asks the same one: each subagent's tab, so a second
/// request shows the open pane instead of a second one, and the pane the next one stacks under.
/// The first subagent's pane opens right of the chat; each later one opens below the newest pane
/// still open, so the chat keeps its width and one column holds them all. Opens run one at a
/// time: a later one stacks under the pane the earlier one moved into, so it waits for that move.
///
/// A subagent pane is a tab on the chat's own acpmux session that shows the subagent's view: it
/// stays a whole chat tab, so closing the chat leaves it working on the same session.
@MainActor
public final class AgentSubagentPanes {
    private var tabs: [String: String] = [:]
    private var order: [String] = []
    private var opening: String?
    private var queue: [(agent: String, focus: Bool)] = []

    public init() {}

    /// The open tab of subagent `agent`; `isOpen` says whether a tab key still exists.
    public func tab(for agent: String, isOpen: (String) -> Bool) -> String? {
        prune(isOpen)
        return tabs[agent]
    }

    /// Starts opening subagent `agent`'s pane; false when another open runs (the request waits
    /// for ``finish()``) or this one already runs.
    public func begin(_ agent: String, focus: Bool) -> Bool {
        guard let opening else {
            self.opening = agent
            return true
        }
        if opening != agent, !queue.contains(where: { $0.agent == agent }) { queue.append((agent, focus)) }
        return false
    }

    /// Ends the open that runs; returns the next waiting request, if any.
    public func finish() -> (agent: String, focus: Bool)? {
        opening = nil
        return queue.isEmpty ? nil : queue.removeFirst()
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

    private func prune(_ isOpen: (String) -> Bool) {
        tabs = tabs.filter { isOpen($0.value) }
        order.removeAll { !isOpen($0) }
    }

    /// The `revealTurn` value that opens a pane on subagent `agent`'s view (the page's
    /// `SUBAGENT_REVEAL`).
    public static func reveal(_ agent: String) -> String { "subagent:\(agent)" }
}
