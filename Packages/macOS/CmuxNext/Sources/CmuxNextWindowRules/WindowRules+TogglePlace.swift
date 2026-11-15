import Foundation

/// Toggle Terminal and Chat's place: a swap lands at the same turn in the other view, both ways
/// (Leo, 2026-11-12: "the terminal ↔ GUI toggle is the sauce", two live views of one session).
/// The match of the chat's prompts against the terminal's rows is Rust's (cmux-window-rules
/// `tabs::place`); ``TerminalChatPlacing`` reads both faces and moves the one about to show.
extension WindowRules {
    public nonisolated struct ToTerminalPlace: Encodable, Equatable, Sendable {
        public var prompts: [String]
        /// The prompt whose turn the chat has in view; nil at its latest message.
        public var at: Int?
        public var screen: String
        public var columns: Int

        public init(prompts: [String], at: Int?, screen: String, columns: Int) {
            self.prompts = prompts
            self.at = at
            self.screen = screen
            self.columns = columns
        }
    }

    public nonisolated struct ToChatPlace: Encodable, Equatable, Sendable {
        public var prompts: [String]
        public var screen: String
        public var columns: Int
        public var top: Int
        public var atBottom: Bool

        public init(prompts: [String], screen: String, columns: Int, top: Int, atBottom: Bool) {
            self.prompts = prompts
            self.screen = screen
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
        call("window_tabs_terminal_place", facts, as: TerminalPlace.self)
    }

    public func chatPlace(_ facts: ToChatPlace) -> ChatPlace? {
        call("window_tabs_chat_place", facts, as: ChatPlace.self)
    }
}

/// The terminal face of a pair, as a swap reads and moves it (`TerminalSession+TogglePlace`).
@MainActor
public protocol TogglePlaceTerminal: AnyObject, Sendable {
    func togglePlaceViewport() -> (top: Int, atBottom: Bool)?
    func togglePlaceScreen() -> (screen: String, columns: Int)?
    func togglePlaceScroll(toRow row: Int?)
}

/// The chat face of a pair, as a swap reads and moves it (`AgentPaneView+TogglePlace`).
@MainActor
public protocol TogglePlaceChat: AnyObject, Sendable {
    var togglePlaceAtLatest: Bool { get }
    func togglePlacePrompts() async -> (prompts: [String], at: Int?)?
    @discardableResult func togglePlaceShow(prompt index: Int?) async -> Bool
}

/// Moves the face about to show to the turn the other one shows, before it shows, so the swap's
/// first frame is already there: no jump after it. Nothing to move (both at their latest) asks
/// nothing of the page, so that swap stays a plain tab selection.
@MainActor
public struct TerminalChatPlacing {
    public let chat: (any TogglePlaceChat)?
    public let terminal: (any TogglePlaceTerminal)?
    let rules: WindowRules

    public init(chat: (any TogglePlaceChat)?, terminal: (any TogglePlaceTerminal)?, rules: WindowRules = WindowRules()) {
        self.chat = chat
        self.terminal = terminal
        self.rules = rules
    }

    /// Whether the swap moves nothing: a face is missing, or both are at their latest.
    public var settled: Bool {
        guard let chat, let viewport = terminal?.togglePlaceViewport() else { return true }
        return chat.togglePlaceAtLatest && viewport.atBottom
    }

    /// Before the terminal shows: to the row of the chat's turn, or its newest rows.
    public func placeTerminal() async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        if chat.togglePlaceAtLatest {
            if !viewport.atBottom { terminal.togglePlaceScroll(toRow: nil) }
            return
        }
        guard let read = await chat.togglePlacePrompts() else { return }
        guard read.at != nil else {
            if !viewport.atBottom { terminal.togglePlaceScroll(toRow: nil) }
            return
        }
        guard let screen = terminal.togglePlaceScreen() else { return }
        let facts = WindowRules.ToTerminalPlace(prompts: read.prompts, at: read.at, screen: screen.screen, columns: screen.columns)
        switch rules.terminalPlace(facts) {
        case .latest?: if !viewport.atBottom { terminal.togglePlaceScroll(toRow: nil) }
        case .row(let row)? where row != viewport.top: terminal.togglePlaceScroll(toRow: row)
        case .row?, .stay?, nil: break
        }
    }

    /// Before the chat shows: to the turn of the terminal's top row, or its latest message.
    public func placeChat() async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        if viewport.atBottom {
            if !chat.togglePlaceAtLatest { await chat.togglePlaceShow(prompt: nil) }
            return
        }
        guard let read = await chat.togglePlacePrompts(), let screen = terminal.togglePlaceScreen() else { return }
        let facts = WindowRules.ToChatPlace(prompts: read.prompts, screen: screen.screen, columns: screen.columns,
                                            top: viewport.top, atBottom: false)
        switch rules.chatPlace(facts) {
        case .latest?: if read.at != nil { await chat.togglePlaceShow(prompt: nil) }
        case .turn(let index)? where index != read.at: await chat.togglePlaceShow(prompt: index)
        case .turn?, .stay?, nil: break
        }
    }
}
