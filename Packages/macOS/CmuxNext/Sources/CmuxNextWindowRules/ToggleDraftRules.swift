import Foundation

/// Toggle Terminal and Chat's draft: the unsent draft goes with a swap, both ways (Leo,
/// 2026-11-12: "the terminal ↔ GUI toggle is the sauce", two live views of one session, instant
/// both ways). What moves is Rust's (cmux-window-rules `tabs::draft`): it reads the terminal's
/// input line out of the bytes the terminal sent its program, moves it only when the harness's
/// input box on screen shows exactly that, and never merges two drafts.
///
/// Its own type over the ``WindowRules`` it calls, like ``TogglePlaceRules``: that type is over its
/// size budget (scripts/cmux-next/check-no-godfiles.sh counts a type's extensions in its module).
public nonisolated struct ToggleDraftRules: Sendable {
    let rules: WindowRules

    public init(rules: WindowRules = WindowRules()) {
        self.rules = rules
    }

    public nonisolated struct ToChatDraft: Encodable, Equatable, Sendable {
        public var typed: [UInt8]
        public var truncated: Bool
        /// The terminal's active rows, one line per row.
        public var screen: String
        public var composerEmpty: Bool

        public init(typed: [UInt8], truncated: Bool, screen: String, composerEmpty: Bool) {
            self.typed = typed
            self.truncated = truncated
            self.screen = screen
            self.composerEmpty = composerEmpty
        }
    }

    public nonisolated struct ToTerminalDraft: Encodable, Equatable, Sendable {
        /// The composer's text when it can leave as text; nil otherwise.
        public var chat: String?
        public var typed: [UInt8]
        public var truncated: Bool
        /// The terminal's active rows: its input box must show nothing.
        public var screen: String

        public init(chat: String?, typed: [UInt8], truncated: Bool, screen: String) {
            self.chat = chat
            self.typed = typed
            self.truncated = truncated
            self.screen = screen
        }
    }

    /// What a swap to the chat does with the terminal's draft.
    public nonisolated enum ChatDraft: Decodable, Equatable, Sendable {
        /// Put `text` in the composer; once it holds it, send `erase` DELs to the terminal.
        case carry(text: String, erase: Int)
        case none

        private enum CodingKeys: String, CodingKey { case draft, text, erase }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .draft) {
            case "carry": self = .carry(text: try container.decode(String.self, forKey: .text),
                                        erase: try container.decode(Int.self, forKey: .erase))
            default: self = .none
            }
        }
    }

    /// What a swap to the terminal does with the composer's draft.
    public nonisolated enum TerminalDraft: Decodable, Equatable, Sendable {
        case paste(String)
        case none

        private enum CodingKeys: String, CodingKey { case draft, text }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .draft) {
            case "paste": self = .paste(try container.decode(String.self, forKey: .text))
            default: self = .none
            }
        }
    }

    public func draftToChat(_ facts: ToChatDraft) -> ChatDraft? {
        rules.call("window_tabs_draft_to_chat", facts, as: ChatDraft.self)
    }

    public func draftToTerminal(_ facts: ToTerminalDraft) -> TerminalDraft? {
        rules.call("window_tabs_draft_to_terminal", facts, as: TerminalDraft.self)
    }
}
