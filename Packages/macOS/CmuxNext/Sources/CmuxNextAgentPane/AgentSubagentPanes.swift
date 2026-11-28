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
    private var queue: [Request] = []

    /// A waiting request: the subagent, whether it takes focus, and the chat tab that asked.
    public struct Request: Sendable { public var agent: String; public var focus: Bool; public var chat: String }

    public init() {}

    private static var sessions: [String: AgentSubagentPanes] = [:]

    /// The tracker of acpmux session `id`, shared by every tab on that session.
    public static func session(_ id: String) -> AgentSubagentPanes {
        if let panes = sessions[id] { return panes }
        let panes = AgentSubagentPanes()
        sessions[id] = panes
        return panes
    }

    /// The open tab of subagent `agent`; `isOpen` says whether a tab key still exists.
    public func tab(for agent: String, isOpen: (String) -> Bool) -> String? {
        prune(isOpen)
        return tabs[agent]
    }

    /// Starts opening subagent `agent`'s pane for chat tab `chat`; false when another open runs (the
    /// request waits for ``finish()``; a repeat that asks for focus keeps that) or this one already runs.
    public func begin(_ agent: String, focus: Bool, chat: String) -> Bool {
        guard let opening else {
            self.opening = agent
            return true
        }
        if let index = queue.firstIndex(where: { $0.agent == agent }) { queue[index].focus = queue[index].focus || focus }
        else if opening != agent { queue.append(Request(agent: agent, focus: focus, chat: chat)) }
        return false
    }

    /// Ends the open that runs; returns the next waiting request, if any.
    public func finish() -> Request? {
        opening = nil
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// What ``open(_:focus:chat:hooks:)`` asks the app for.
    public struct Hooks {
        /// Whether a tab key still exists.
        public var isOpen: (String) -> Bool
        /// Focuses tab `key`; `script` for a focus the user did not ask for (a refocus).
        public var focus: (_ key: String, _ script: Bool) -> Void
        /// Opens the pane beside tab `anchor` (below it with `down`, else right of it); calls
        /// `created` with the new tab, then `finished` with whether it moved. False when nothing opened.
        public var place: (_ anchor: String, _ down: Bool, _ created: @escaping @MainActor (String) -> Void,
                           _ finished: @escaping @MainActor (Bool) -> Void) -> Bool
        /// Runs a waiting request.
        public var again: (Request) -> Void

        public init(isOpen: @escaping (String) -> Bool, focus: @escaping (String, Bool) -> Void,
                    place: @escaping (String, Bool, @escaping @MainActor (String) -> Void, @escaping @MainActor (Bool) -> Void) -> Bool,
                    again: @escaping (Request) -> Void) {
            self.isOpen = isOpen
            self.focus = focus
            self.place = place
            self.again = again
        }
    }

    /// Shows subagent `agent`'s pane for chat tab `chat`: focuses the open one (with `focus`), or
    /// opens one right of the chat, or below the newest subagent pane; one open at a time. An
    /// unfocused open moves the tab with the daemon's `keep_focus` (cx-3hw0i), so the chat keeps
    /// focus throughout. False when nothing opened.
    public func open(_ agent: String, focus: Bool, chat: String, hooks: Hooks) -> Bool {
        if let open = tab(for: agent, isOpen: hooks.isOpen) {
            if focus { hooks.focus(open, false) }
            return true
        }
        guard begin(agent, focus: focus, chat: chat) else { return true }
        let next: @MainActor (Bool) -> Void = { [weak self] _ in
            if let request = self?.finish() { hooks.again(request) }
        }
        let stack = stackAnchor(isOpen: hooks.isOpen)
        let created: @MainActor (String) -> Void = { [weak self] key in self?.record(agent, tab: key) }
        let opened = hooks.place(stack ?? chat, stack != nil, created, next)
        if !opened { next(false) }
        return opened
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
