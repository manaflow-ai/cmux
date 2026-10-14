/// Where a chat's subagents open (`chat.subagentPane`), one tracker per acpmux session, so every
/// pane on that session asks the same one: each subagent's tab, so a second request shows the open
/// one instead of a second one, and the pane the next tiled one stacks under.
///
/// A subagent opens as a tab in the pane right of the chat (open beside, ChatBeside), the way a
/// row's click opens it. Tile subagents (`tile`) opens each in a pane of its own instead: the first
/// right of the chat, each later one below the newest tiled pane still open, so the chat keeps its
/// width and one column holds them all, kept equal in height. Opens run one at a time: a later one
/// stacks under the pane the earlier one moved into, so it waits for that move.
///
/// A subagent's tab is a tab on the chat's own acpmux session that shows the subagent's view: it
/// stays a whole chat tab, so closing the chat leaves it working on the same session.
@MainActor
public final class AgentSubagentPanes {
    private var tabs: [String: String] = [:]
    /// The tiled tabs, oldest first.
    private var order: [String] = []
    private var opening: String?
    private var queue: [Request] = []
    /// The watch that keeps the tiled panes equal as they close (the app's, one per session).
    public var balancing: Task<Void, Never>? {
        didSet { oldValue?.cancel() }
    }

    /// How a subagent opens: `focus` moves keyboard focus to it, `tile` gives it a pane of its own,
    /// and `title` (its task) names its tab.
    public nonisolated struct Open: Equatable, Sendable {
        public var focus: Bool
        public var tile: Bool
        public var title: String?

        public init(focus: Bool, tile: Bool = false, title: String? = nil) {
            self.focus = focus
            self.tile = tile
            self.title = title
        }

        /// From `chat.subagentPane`'s params; a title is one line of at most 120 characters.
        public init(_ params: [String: Any]?) {
            let title = (params?["title"] as? String)?.split(whereSeparator: \.isNewline).first.map(String.init)
            self.init(focus: params?["focus"] as? Bool == true, tile: params?["tile"] as? Bool == true,
                      title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) })
        }
    }

    /// A waiting request: the subagent, how it opens, and the chat tab that asked.
    public struct Request: Sendable { public var agent: String; public var how: Open; public var chat: String }

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

    /// Starts opening subagent `agent` for chat tab `chat`; false when another open runs (the
    /// request waits for ``finish()``; a repeat that asks for focus or a tile keeps that) or this one
    /// already runs (a tile request for it still waits: the running open may be a tab).
    public func begin(_ agent: String, how: Open, chat: String) -> Bool {
        guard let opening else {
            self.opening = agent
            return true
        }
        if let index = queue.firstIndex(where: { $0.agent == agent }) {
            queue[index].how.focus = queue[index].how.focus || how.focus
            queue[index].how.tile = queue[index].how.tile || how.tile
            queue[index].how.title = how.title ?? queue[index].how.title
        } else if opening != agent || how.tile { queue.append(Request(agent: agent, how: how, chat: chat)) }
        return false
    }

    /// Ends the open that runs; returns the next waiting request, if any.
    public func finish() -> Request? {
        opening = nil
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// What ``open(_:how:chat:hooks:)`` asks the app for.
    public struct Hooks {
        /// Whether a tab key still exists.
        public var isOpen: (String) -> Bool
        /// Shows tab `key` again: focuses it with `focus`, else selects it in its pane.
        public var show: (_ key: String, _ focus: Bool) -> Void
        /// Opens the subagent's tab: tiled, beside tab `anchor` (below it with `down`, else right of
        /// it), or in the pane right of the chat; calls `created` with the new tab, then `finished`
        /// with whether it is in place. False when nothing opened.
        public var place: (_ anchor: String, _ down: Bool, _ created: @escaping @MainActor (String) -> Void,
                           _ finished: @escaping @MainActor (Bool) -> Void) -> Bool
        /// Runs a waiting request.
        public var again: (Request) -> Void
        /// Closes tab `key`: a subagent's tab that a tiled pane replaces.
        public var close: (_ key: String) -> Void

        public init(isOpen: @escaping (String) -> Bool, show: @escaping (String, Bool) -> Void,
                    place: @escaping (String, Bool, @escaping @MainActor (String) -> Void, @escaping @MainActor (Bool) -> Void) -> Bool,
                    again: @escaping (Request) -> Void, close: @escaping (String) -> Void = { _ in }) {
            self.isOpen = isOpen
            self.show = show
            self.place = place
            self.again = again
            self.close = close
        }
    }

    /// Shows subagent `agent` for chat tab `chat`: shows its open tab, or opens one as `how` asks (in
    /// the pane right of the chat, or tiled: right of the chat, or below the newest tiled pane); one
    /// open at a time. An unfocused open moves the tab with the daemon's `keep_focus` (cx-3hw0i), so
    /// the chat keeps focus throughout. A tiled open of one open as a tab (a row's click) closes that
    /// tab for the pane, so a subagent keeps one view. False when nothing opened.
    public func open(_ agent: String, how: Open, chat: String, hooks: Hooks) -> Bool {
        if let open = tab(for: agent, isOpen: hooks.isOpen), !how.tile || order.contains(open) {
            hooks.show(open, how.focus)
            return true
        }
        guard begin(agent, how: how, chat: chat) else { return true }
        if let plain = tabs.removeValue(forKey: agent) { hooks.close(plain) }
        let next: @MainActor (Bool) -> Void = { [weak self] _ in
            if let request = self?.finish() { hooks.again(request) }
        }
        let stack = how.tile ? stackAnchor(isOpen: hooks.isOpen) : nil
        let created: @MainActor (String) -> Void = { [weak self] key in self?.record(agent, tab: key, tiled: how.tile) }
        let opened = hooks.place(stack ?? chat, stack != nil, created, next)
        if !opened { next(false) }
        return opened
    }

    /// The tab a new tiled pane stacks under: the newest tiled one open, or nil for none.
    public func stackAnchor(isOpen: (String) -> Bool) -> String? {
        tiled(isOpen: isOpen).last
    }

    /// The tiled tabs still open, oldest first.
    public func tiled(isOpen: (String) -> Bool) -> [String] {
        prune(isOpen)
        return order
    }

    /// Records the tab that shows subagent `agent`; a `tiled` one is a pane of the stack.
    public func record(_ agent: String, tab key: String, tiled: Bool = true) {
        tabs[agent] = key
        order.removeAll { $0 == key }
        if tiled { order.append(key) }
    }

    private func prune(_ isOpen: (String) -> Bool) {
        tabs = tabs.filter { isOpen($0.value) }
        order.removeAll { !isOpen($0) }
    }

    /// The `revealTurn` value that opens a pane on subagent `agent`'s view (the page's
    /// `SUBAGENT_REVEAL`).
    public static func reveal(_ agent: String) -> String { "subagent:\(agent)" }

    /// The `revealTurn` value that asks a chat's page to tile its running subagents (Tile
    /// Subagents; the page's `SUBAGENTS_TILE`).
    public static let tileReveal = "subagents:tile"
}
