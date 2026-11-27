/// The notification verbs and the history actions (cmux-window-rules `notifications`, `history`).
extension WindowRules {
    /// A verb over the unread tabs.
    public nonisolated enum UnreadVerb: String, Encodable, Sendable {
        case jumpToUnread, markOldestAndJumpNext, markAllRead, readLatest
    }

    /// What an unread verb does: indices into the unread tabs sent.
    public nonisolated struct UnreadPlan: Decodable, Equatable, Sendable {
        /// Acknowledged, in this order.
        public var acknowledge: [Int]
        /// Shown, and its notification opened.
        public var open: Int?
        /// `noUnread`: there is no unread tab.
        public var refusal: String?
    }

    /// What `verb` does with the unread tabs, given each one's notification time (tree order).
    public func unreadPlan(_ verb: UnreadVerb, createdAt: [UInt64?]) -> UnreadPlan? {
        struct Tab: Encodable { var createdAtMs: UInt64? }
        struct Request: Encodable { var verb: UnreadVerb, unread: [Tab] }
        return call("window_notifications_plan", Request(verb: verb, unread: createdAt.map(Tab.init)), as: UnreadPlan.self)
    }

    /// The prompted tab whose agent was prompted last (an index into `prompts`); nil when none was.
    public func lastPrompt(_ prompts: [UInt64]) -> Int? {
        struct Request: Encodable { var prompts: [UInt64] }
        struct Reply: Decodable { var index: Int? }
        return call("window_notifications_last_prompt", Request(prompts: prompts), as: Reply.self)?.index
    }

    /// The tab whose agent was prompted last, of `tabs` in tree order (a tie goes to the first in the
    /// tree: `last_prompt` breaks ties by the order it is sent); nil when none was prompted.
    public func lastPrompted<Tab>(_ tabs: [Tab], prompt: (Tab) -> UInt64?) -> Tab? {
        let prompted = tabs.compactMap { tab in prompt(tab).map { (tab, $0) } }
        guard let index = lastPrompt(prompted.map(\.1)), prompted.indices.contains(index) else { return nil }
        return prompted[index].0
    }

    /// Mute Workspace: the muted keys after toggling `key` (a `legacy` key unmutes with it), sorted.
    public func toggleMute(_ muted: [String], key: String, legacy: String?) -> [String]? {
        struct Request: Encodable { var muted: [String], key: String, legacy: String? }
        struct Reply: Decodable { var muted: [String] }
        return call("window_notifications_toggle_mute", Request(muted: muted, key: key, legacy: legacy), as: Reply.self)?.muted
    }

    /// Toggle Banners: `notifications.desktop` after the toggle.
    public func toggleBanners(_ desktop: String) -> String? {
        struct Request: Encodable { var desktop: String }
        struct Reply: Decodable { var desktop: String }
        return call("window_notifications_toggle_banners", Request(desktop: desktop), as: Reply.self)?.desktop
    }

    /// The history actions' table.
    public nonisolated struct HistoryActions: Decodable, Equatable, Sendable {
        public nonisolated struct Walk: Decodable, Equatable, Sendable {
            public var action: String
            /// `back`, `forward` or `last`.
            public var direction: String
            /// `nothingBack`, `nothingForward` or `nothingLast`.
            public var nowhere: String
        }

        public nonisolated struct Page: Decodable, Equatable, Sendable {
            public var action: String
            /// `locations`, `closed`, `search` or `commands`.
            public var page: String
        }

        public var walks: [Walk]
        public var pages: [Page]
        /// The actions that open the History page.
        public var historyPage: [String]
    }

    public func historyActions() -> HistoryActions? {
        struct Request: Encodable {}
        return call("window_history_actions", Request(), as: HistoryActions.self)
    }

    /// What Undo Layout Change does after the daemon's answer.
    public nonisolated struct UndoReply: Decodable, Equatable, Sendable {
        /// The revision the next Undo confirms.
        public var pending: UInt64?
        /// It waits for a confirmation because it closes this many panes.
        public var closesPanes: Int?
    }

    public func undoReply(confirmationRequired: Bool, revision: UInt64?, closesPanes: Int?) -> UndoReply? {
        struct Request: Encodable { var confirmationRequired: Bool, revision: UInt64?, closesPanes: Int? }
        return call("window_history_undo_reply", Request(confirmationRequired: confirmationRequired, revision: revision, closesPanes: closesPanes),
                    as: UndoReply.self)
    }
}
