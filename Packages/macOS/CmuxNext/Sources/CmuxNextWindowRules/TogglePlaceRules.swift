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

    /// Going to the terminal, once the chat named its turn: what to read of its screen.
    public nonisolated struct TerminalReadFacts: Encodable, Equatable, Sendable {
        /// The prompt whose turn the chat has in view; nil at its latest message.
        public var at: Int?
        /// The screen's rows, its history included.
        public var total: Int
        /// The most rows a swap reads.
        public var rows: Int

        public init(at: Int?, total: Int, rows: Int) {
            (self.at, self.total, self.rows) = (at, total, rows)
        }
    }

    /// What the app reads of the terminal before it shows (cmux-window-rules `tabs::place::terminal_read`).
    public nonisolated enum TerminalRead: Decodable, Equatable, Sendable {
        /// Nothing: the terminal goes to its newest rows.
        case latest
        /// Rows from `base` on: from the viewport's top (moved there first) when `base` is above 0, else through it.
        case screen(base: Int, fromViewportTop: Bool)

        private enum CodingKeys: String, CodingKey { case read, base, fromViewportTop }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .read) {
            case "latest": self = .latest
            case "screen": self = .screen(base: try container.decode(Int.self, forKey: .base),
                                          fromViewportTop: try container.decode(Bool.self, forKey: .fromViewportTop))
            case let other: throw DecodingError.dataCorruptedError(forKey: .read, in: container, debugDescription: "read \(other)")
            }
        }
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

    /// How the terminal scrolls before it shows (`tabs::place::terminal_scroll`).
    public nonisolated enum TerminalScroll: Decodable, Equatable, Sendable {
        /// To its newest rows.
        case latest
        /// Screen row `row` at the viewport's top.
        case row(Int)
        /// Not at all.
        case keep

        private enum CodingKeys: String, CodingKey { case scroll, row }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .scroll) {
            case "latest": self = .latest
            case "row": self = .row(try container.decode(Int.self, forKey: .row))
            case "keep": self = .keep
            case let other: throw DecodingError.dataCorruptedError(forKey: .scroll, in: container, debugDescription: "scroll \(other)")
            }
        }
    }

    /// Going to the chat, the terminal still showing: its viewport and whether the chat is at its latest message.
    public nonisolated struct ChatReadFacts: Encodable, Equatable, Sendable {
        public var top, visible, total: Int
        public var atBottom, atLatest: Bool
        public var rows: Int

        public init(top: Int, visible: Int, total: Int, atBottom: Bool, atLatest: Bool, rows: Int) {
            (self.top, self.visible, self.total, self.atBottom, self.atLatest, self.rows) = (top, visible, total, atBottom, atLatest, rows)
        }
    }

    /// What the app does first going to the chat (`tabs::place::chat_read`).
    public nonisolated enum ChatRead: Decodable, Equatable, Sendable {
        /// The chat goes to its latest message; `show` false: it is there already.
        case latest(show: Bool)
        /// Read the chat's prompts, then the terminal's rows from `base` on.
        case screen(base: Int, fromViewportTop: Bool, throughViewportBottom: Bool)
        /// Neither side of the viewport fits: the chat stays.
        case stay

        private enum CodingKeys: String, CodingKey { case read, show, base, fromViewportTop, throughViewportBottom }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .read) {
            case "latest": self = .latest(show: try container.decode(Bool.self, forKey: .show))
            case "screen": self = .screen(base: try container.decode(Int.self, forKey: .base),
                                          fromViewportTop: try container.decode(Bool.self, forKey: .fromViewportTop),
                                          throughViewportBottom: try container.decode(Bool.self, forKey: .throughViewportBottom))
            case "stay": self = .stay
            case let other: throw DecodingError.dataCorruptedError(forKey: .read, in: container, debugDescription: "read \(other)")
            }
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

    /// What the chat shows before it shows (`tabs::place::chat_show`).
    public nonisolated enum ChatShow: Decodable, Equatable, Sendable {
        case latest
        case turn(Int)
        case stay

        private enum CodingKeys: String, CodingKey { case show, index }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .show) {
            case "latest": self = .latest
            case "turn": self = .turn(try container.decode(Int.self, forKey: .index))
            case "stay": self = .stay
            case let other: throw DecodingError.dataCorruptedError(forKey: .show, in: container, debugDescription: "show \(other)")
            }
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
