/// Where a chat's side sessions open (`chat.sideChat`: New side chat and the side sessions `/btw`
/// starts; `chat.offer.open`: Session Info's sessions and the transcript's session cards), one
/// tracker per acpmux chat session so every tab on that chat asks the same one. Each opens where
/// ``RightColumnPlacement`` puts anything opened on the right of the chat: a split right of it,
/// else one split below what is already on the right, else a tab in the right column's lower pane
/// (Leo 2026-10-30: "if there's already a thing on the right, there should be logic for just
/// putting it on the lower pane of the right"). Opens run one at a time: a later one waits for the
/// earlier one's move, so it reads the column that move made.
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
        /// The right column beside chat tab `key` as the window shows it now.
        public var column: (String) -> RightColumnPlacement.Column
        /// Opens `session` focused where `decision` says (its panes are ``RightColumnPlacement/Column``
        /// keys); calls `created` with the new tab, then `finished` once it is in place. False when
        /// nothing opened.
        public var place: (_ decision: RightColumnPlacement.Decision<String>, _ session: String,
                           _ created: @escaping @MainActor (String) -> Void, _ finished: @escaping @MainActor () -> Void) -> Bool

        public init(pane: @escaping (String) -> String?, column: @escaping (String) -> RightColumnPlacement.Column,
                    place: @escaping (RightColumnPlacement.Decision<String>, String, @escaping @MainActor (String) -> Void, @escaping @MainActor () -> Void) -> Bool) {
            self.pane = pane
            self.column = column
            self.place = place
        }
    }

    /// Opens side session `session` of chat tab `chat` where ``RightColumnPlacement`` says. False
    /// when nothing opened (a waiting open answers true).
    @discardableResult
    public func open(_ session: String, chat: String, hooks: Hooks) -> Bool {
        guard !opening else {
            queue.append((session, chat, hooks))
            return true
        }
        opening = true
        pane = hooks.pane
        tabs.removeAll { hooks.pane($0) == nil }
        let created: @MainActor (String) -> Void = { [weak self] key in self?.record(key) }
        let finished: @MainActor () -> Void = { [weak self] in self?.next() }
        let opened = hooks.place(RightColumnPlacement.decide(hooks.column(chat)), session, created, finished)
        if !opened { next() }
        return opened
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
