/// The one right pane a chat's side sessions open in (`chat.sideChat`: New side chat, and the side
/// sessions `/btw` starts), one tracker per acpmux chat session so every tab on that chat asks the
/// same one. The first side session opens in a split right of the chat; each later one opens as a
/// tab in the pane that holds the newest side session still open beside the chat, so one pane holds
/// them all (Leo 2026-10-14: chat entities open as tabs in one right pane). A side tab the person
/// moved back into the chat's own pane is not that pane. Opens run one at a time: a later one waits
/// for the earlier one's move, so it finds the pane the earlier one moved into.
@MainActor
public final class AgentSidePanes {
    private var tabs: [String] = []
    private var opening = false
    private var queue: [(session: String, chat: String, hooks: Hooks)] = []
    /// The pane lookup of the latest open, so an idle tracker can tell its side tabs closed.
    private var pane: ((String) -> String?)?

    public init() {}

    private static var chats: [String: AgentSidePanes] = [:]

    /// The tracker of acpmux chat session `id`, shared by every tab on that chat. Trackers of other
    /// chats whose side tabs all closed are dropped first, so none outlives its side pane.
    public static func chat(_ id: String) -> AgentSidePanes {
        chats = chats.filter { $0.key == id || !$0.value.isSpent }
        if let panes = chats[id] { return panes }
        let panes = AgentSidePanes()
        chats[id] = panes
        return panes
    }

    /// What ``open(_:chat:hooks:)`` asks the app for.
    public struct Hooks {
        /// The pane that holds tab `key`, nil when the tab is closed.
        public var pane: (String) -> String?
        /// Opens `session` as a tab in the pane that holds tab `anchor`, focused; calls `created`
        /// with the new tab, then `finished`. False when nothing opened.
        public var addTab: (_ anchor: String, _ session: String, _ created: @escaping @MainActor (String) -> Void,
                            _ finished: @escaping @MainActor () -> Void) -> Bool
        /// Opens `session` in a new split right of the chat's tab, focused; calls `created` with
        /// the new tab, then `finished` once it moved. False when nothing opened.
        public var split: (_ session: String, _ created: @escaping @MainActor (String) -> Void,
                           _ finished: @escaping @MainActor () -> Void) -> Bool

        public init(pane: @escaping (String) -> String?,
                    addTab: @escaping (String, String, @escaping @MainActor (String) -> Void, @escaping @MainActor () -> Void) -> Bool,
                    split: @escaping (String, @escaping @MainActor (String) -> Void, @escaping @MainActor () -> Void) -> Bool) {
            self.pane = pane
            self.addTab = addTab
            self.split = split
        }
    }

    /// Opens side session `session` of chat tab `chat`: a tab in the side pane when one is open,
    /// else a split right of the chat. False when nothing opened (a waiting open answers true).
    @discardableResult
    public func open(_ session: String, chat: String, hooks: Hooks) -> Bool {
        guard !opening else {
            queue.append((session, chat, hooks))
            return true
        }
        opening = true
        pane = hooks.pane
        let created: @MainActor (String) -> Void = { [weak self] key in self?.record(key) }
        let finished: @MainActor () -> Void = { [weak self] in self?.next() }
        let opened: Bool
        if let anchor = sidePaneTab(chat: chat, pane: hooks.pane) {
            opened = hooks.addTab(anchor, session, created, finished)
        } else {
            opened = hooks.split(session, created, finished)
        }
        if !opened { next() }
        return opened
    }

    /// ``open(_:chat:hooks:)`` with one placement: `place(anchor, created, finished)` opens `session`
    /// focused as a tab in the pane that holds tab `anchor`, or (nil) in a new split right of the chat.
    @discardableResult
    public func open(_ session: String, chat: String, pane: @escaping (String) -> String?,
                     place: @escaping (_ anchor: String?, _ created: @escaping @MainActor (String) -> Void, _ finished: @escaping @MainActor () -> Void) -> Bool) -> Bool {
        open(session, chat: chat, hooks: Hooks(pane: pane, addTab: { anchor, _, created, finished in place(anchor, created, finished) },
                                               split: { _, created, finished in place(nil, created, finished) }))
    }

    /// The newest side tab still open in a pane other than the chat's, nil for none.
    private func sidePaneTab(chat: String, pane: (String) -> String?) -> String? {
        tabs.removeAll { pane($0) == nil }
        let chatPane = pane(chat)
        return tabs.last { pane($0) != chatPane }
    }

    /// Idle, with no side tab still open.
    private var isSpent: Bool {
        guard !opening, queue.isEmpty, let pane else { return false }
        return tabs.allSatisfy { pane($0) == nil }
    }

    private func record(_ key: String) {
        tabs.removeAll { $0 == key }
        tabs.append(key)
    }

    private func next() {
        opening = false
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        open(request.session, chat: request.chat, hooks: request.hooks)
    }
}
