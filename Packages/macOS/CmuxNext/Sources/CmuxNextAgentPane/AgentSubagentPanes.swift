import AppKit
import CmuxNextCompat

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
    /// The subagent whose open runs without focus but that the person asked to see meanwhile (a
    /// click while its pane opens on its own), and when: its pane takes focus once it has opened,
    /// unless the person did something else first (``userActed()``) or ``focusBound`` passed.
    private var focusOnceOpen: (agent: String, at: ContinuousClock.Instant)?
    /// Stops watching for the person's next action while focus is owed.
    private var stopWatching: (() -> Void)?
    /// How long an owed focus waits for its pane: one that lands later takes no focus, as the
    /// person has moved on (an open can take 20 s).
    public static let focusBound: Duration = .seconds(2)
    private var queue: [Request] = []

    /// A waiting request: the subagent, whether it takes focus, the chat tab that asked, and when
    /// focus was asked for (a focus owed like ``focusOnceOpen``).
    public struct Request: Sendable { public var agent: String; public var focus: Bool; public var chat: String; public var at: ContinuousClock.Instant }

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
    /// request waits for ``finish()``; a repeat that asks for focus keeps that, from `now`) or this one already runs.
    public func begin(_ agent: String, focus: Bool, chat: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard let opening else {
            self.opening = agent
            return true
        }
        if opening == agent, focus { focusOnceOpen = (agent, now) }
        if let index = queue.firstIndex(where: { $0.agent == agent }) {
            if focus { (queue[index].focus, queue[index].at) = (true, now) }
        } else if opening != agent { queue.append(Request(agent: agent, focus: focus, chat: chat, at: now)) }
        return false
    }

    /// Ends the open that runs; returns the next waiting request, if any, without focus once its
    /// ``focusBound`` has passed at `now`.
    public func finish(now: ContinuousClock.Instant = .now) -> Request? {
        opening = nil
        focusOnceOpen = nil
        guard !queue.isEmpty else { return settled(nil) }
        var next = queue.removeFirst()
        if next.focus, now - next.at > Self.focusBound { next.focus = false }
        return settled(next)
    }

    /// Whether subagent `agent`'s running open still owes the person focus at `now`
    /// (``begin(_:focus:chat:now:)``).
    func owesFocus(_ agent: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard let focusOnceOpen, focusOnceOpen.agent == agent else { return false }
        return now - focusOnceOpen.at <= Self.focusBound
    }

    /// The person clicked, pressed a key or moved focus after asking: their latest action wins, so
    /// no owed focus lands.
    public func userActed() {
        focusOnceOpen = nil
        for index in queue.indices { queue[index].focus = false }
        _ = settled(nil)
    }

    /// Stops watching for the person's next action once no focus is owed; returns `request`.
    private func settled(_ request: Request?) -> Request? {
        if focusOnceOpen == nil, !queue.contains(where: { $0.focus }) {
            stopWatching?()
            stopWatching = nil
        }
        return request
    }

    /// What ``open(_:focus:chat:hooks:)`` asks the app for.
    public struct Hooks {
        /// Whether a tab key still exists.
        public var isOpen: (String) -> Bool
        /// Focuses tab `key`; `script` for a focus the user did not ask for (a refocus).
        public var focus: (_ key: String, _ script: Bool) -> Void
        /// Restores the requested subagent view when reusing an existing tab.
        public var reveal: (_ key: String, _ agent: String) -> Void
        /// Opens the pane beside tab `anchor` (below it with `down`, else right of it); calls
        /// `created` with the new tab, then `finished` with whether it moved. False when nothing opened.
        public var place: (_ anchor: String, _ down: Bool, _ created: @escaping @MainActor (String) -> Void,
                           _ finished: @escaping @MainActor (Bool) -> Void) -> Bool
        /// Runs a waiting request.
        public var again: (Request) -> Void
        /// The time, for ``focusBound``.
        public var now: () -> ContinuousClock.Instant
        /// Calls `acted` on the person's next action (``watchUser(_:)``); returns what stops watching.
        public var watchUser: (_ acted: @escaping @MainActor @Sendable () -> Void) -> () -> Void

        public init(isOpen: @escaping (String) -> Bool, focus: @escaping (String, Bool) -> Void,
                    reveal: @escaping (String, String) -> Void = { _, _ in },
                    place: @escaping (String, Bool, @escaping @MainActor (String) -> Void, @escaping @MainActor (Bool) -> Void) -> Bool,
                    again: @escaping (Request) -> Void, now: @escaping () -> ContinuousClock.Instant = { .now },
                    watchUser: @escaping (@escaping @MainActor @Sendable () -> Void) -> () -> Void = AgentSubagentPanes.watchUser) {
            self.isOpen = isOpen
            self.focus = focus
            self.reveal = reveal
            self.place = place
            self.again = again
            self.now = now
            self.watchUser = watchUser
        }
    }

    /// Shows subagent `agent`'s pane for chat tab `chat`: focuses the open one (with `focus`), or
    /// opens one right of the chat, or below the newest subagent pane; one open at a time. An
    /// unfocused open moves the tab with the daemon's `keep_focus` (cx-3hw0i), so the chat keeps
    /// focus throughout. False when nothing opened.
    public func open(_ agent: String, focus: Bool, chat: String, hooks: Hooks) -> Bool {
        if let open = tab(for: agent, isOpen: hooks.isOpen) {
            hooks.reveal(open, agent)
            if focus { hooks.focus(open, false) }
            return true
        }
        guard begin(agent, focus: focus, chat: chat, now: hooks.now()) else {
            if focus, stopWatching == nil {
                stopWatching = hooks.watchUser { [weak self] in self?.userActed() }
            }
            return true
        }
        let next: @MainActor (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            // A click that came while this pane opened without focus, with nothing done since and
            // not too long ago: the pane takes it now.
            if !focus, self.owesFocus(agent, now: hooks.now()), let key = self.tab(for: agent, isOpen: hooks.isOpen) { hooks.focus(key, false) }
            if let request = self.finish(now: hooks.now()) { hooks.again(request) }
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

    /// Calls `acted` on the next click or key press in the app, or when another window takes the
    /// keyboard or the app resigns active; returns what stops watching.
    nonisolated public static func watchUser(_ acted: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard Thread.isMainThread else { return event }
            // main-proof: guarded by Thread.isMainThread above (AppKit calls local monitors on main)
            MainActor.assumeIsolated { acted() }
            return event
        }
        let center = NotificationCenter.default
        let observers = [NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification].map { name in
            MainActorObservation(name, center: center) {
                acted()
            }
        }
        return {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach { $0.cancel() }
        }
    }

    /// The `revealTurn` value that opens a pane on subagent `agent`'s view (the page's
    /// `SUBAGENT_REVEAL`).
    public static func reveal(_ agent: String) -> String { "subagent:\(agent)" }
}
