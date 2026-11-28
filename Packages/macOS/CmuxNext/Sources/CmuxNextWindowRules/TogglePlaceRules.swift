import Foundation

/// Toggle Terminal and Chat's place: a swap lands at the same turn in the other view, both ways
/// (Leo, 2026-11-12: "the terminal ↔ GUI toggle is the sauce", two live views of one session).
/// The match of the chat's prompts against the terminal's rows is Rust's (cmux-window-rules
/// `tabs::place`), and so is what a swap reads and how it moves; ``TerminalChatPlacing`` reads both faces and moves the one
/// about to show.
///
/// Its own type over the ``WindowRules`` it calls, not an extension of it: that type is over its
/// size budget (scripts/cmux-next/check-no-godfiles.sh counts a type's extensions in its module).
public nonisolated struct TogglePlaceRules: Sendable {
    let rules: WindowRules

    public init(rules: WindowRules = WindowRules()) {
        self.rules = rules
    }

    /// Going to the terminal, its screen read: the match's facts and where the viewport was before the read.
    public nonisolated struct ToTerminalScroll: Encodable, Equatable, Sendable {
        public var prompts: [String]
        public var at: Int?
        /// Screen rows from row `base` on, one line per row.
        public var screen: String
        public var base: Int
        public var columns: Int
        public var top: Int
        public var atBottom: Bool

        public init(prompts: [String], at: Int?, screen: String, base: Int, columns: Int, top: Int, atBottom: Bool) {
            (self.prompts, self.at, self.screen, self.base, self.columns) = (prompts, at, screen, base, columns)
            (self.top, self.atBottom) = (top, atBottom)
        }
    }

    /// Going to the chat, the terminal's rows read: the match's facts and the chat's turn now.
    public nonisolated struct ToChatShow: Encodable, Equatable, Sendable {
        public var prompts: [String]
        /// Screen rows from row `base` on: from the start through the viewport (0), or from the viewport's top.
        public var screen: String
        public var base: Int
        public var columns: Int
        public var top: Int
        public var atBottom: Bool
        /// The prompt whose turn the chat shows; nil at its latest message.
        public var at: Int?

        public init(prompts: [String], screen: String, base: Int, columns: Int, top: Int, atBottom: Bool, at: Int?) {
            (self.prompts, self.screen, self.base, self.columns) = (prompts, screen, base, columns)
            (self.top, self.atBottom, self.at) = (top, atBottom, at)
        }
    }

    public func terminalRead(_ facts: TerminalReadFacts) -> TerminalRead? {
        rules.call("window_tabs_terminal_read", facts, as: TerminalRead.self)
    }

    public func terminalScroll(_ facts: ToTerminalScroll) -> TerminalScroll? {
        rules.call("window_tabs_terminal_scroll", facts, as: TerminalScroll.self)
    }

    public func chatRead(_ facts: ChatReadFacts) -> ChatRead? {
        rules.call("window_tabs_chat_read", facts, as: ChatRead.self)
    }

    public func chatShow(_ facts: ToChatShow) -> ChatShow? {
        rules.call("window_tabs_chat_show", facts, as: ChatShow.self)
    }
}

extension TogglePlaceRules.TerminalReadFacts {
    public init(at: Int?, total: Int, rows: Int) {
        (self.at, self.total, self.rows) = (at, total, rows)
    }
}

extension TogglePlaceRules.ChatReadFacts {
    public init(top: Int, visible: Int, total: Int, atBottom: Bool, atLatest: Bool, rows: Int) {
        (self.top, self.visible, self.total, self.atBottom, self.atLatest, self.rows) = (top, visible, total, atBottom, atLatest, rows)
    }
}
