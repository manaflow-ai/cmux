import Foundation

/// Toggle Terminal and Chat's place: a swap lands at the same turn in the other view, both ways
/// (Leo, 2026-11-12: "the terminal ↔ GUI toggle is the sauce", two live views of one session).
/// The match of the chat's prompts against the terminal's rows is Rust's (cmux-window-rules
/// `tabs::place`); ``TerminalChatPlacing`` reads both faces and moves the one about to show.
///
/// Its own type over the ``WindowRules`` it calls, not an extension of it: that type is over its
/// size budget (scripts/cmux-next/check-no-godfiles.sh counts a type's extensions in its module).
public nonisolated struct TogglePlaceRules: Sendable {
    let rules: WindowRules

    public init(rules: WindowRules = WindowRules()) {
        self.rules = rules
    }

    public nonisolated struct ToTerminalPlace: Encodable, Equatable, Sendable {
        public var prompts: [String]
        /// The prompt whose turn the chat has in view; nil at its latest message.
        public var at: Int?
        /// Screen rows from row `base` on, one line per row.
        public var screen: String
        public var base: Int
        public var columns: Int

        public init(prompts: [String], at: Int?, screen: String, base: Int, columns: Int) {
            self.prompts = prompts
            self.at = at
            self.screen = screen
            self.base = base
            self.columns = columns
        }
    }

    public nonisolated struct ToChatPlace: Encodable, Equatable, Sendable {
        public var prompts: [String]
        /// Screen rows from row `base` on: from the start through the viewport (0), or from the viewport's top.
        public var screen: String
        public var base: Int
        public var columns: Int
        public var top: Int
        public var atBottom: Bool

        public init(prompts: [String], screen: String, base: Int, columns: Int, top: Int, atBottom: Bool) {
            self.prompts = prompts
            self.screen = screen
            self.base = base
            self.columns = columns
            self.top = top
            self.atBottom = atBottom
        }
    }

    /// Where the terminal scrolls before it shows.
    public nonisolated enum TerminalPlace: Decodable, Equatable, Sendable {
        case latest
        case row(Int)
        case stay

        private enum CodingKeys: String, CodingKey { case place, row }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .place) {
            case "latest": self = .latest
            case "row": self = .row(try container.decode(Int.self, forKey: .row))
            default: self = .stay
            }
        }
    }

    /// Where the chat scrolls before it shows.
    public nonisolated enum ChatPlace: Decodable, Equatable, Sendable {
        case latest
        case turn(Int)
        case stay

        private enum CodingKeys: String, CodingKey { case place, index }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .place) {
            case "latest": self = .latest
            case "turn": self = .turn(try container.decode(Int.self, forKey: .index))
            default: self = .stay
            }
        }
    }

    public func terminalPlace(_ facts: ToTerminalPlace) -> TerminalPlace? {
        rules.call("window_tabs_terminal_place", facts, as: TerminalPlace.self)
    }

    public func chatPlace(_ facts: ToChatPlace) -> ChatPlace? {
        rules.call("window_tabs_chat_place", facts, as: ChatPlace.self)
    }
}
