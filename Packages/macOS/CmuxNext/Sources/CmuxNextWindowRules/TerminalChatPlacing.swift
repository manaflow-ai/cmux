import Foundation

/// The terminal face of a pair, as a swap reads and moves it (`TerminalSession+TogglePlace`, conformed in the App).
@MainActor
public protocol TogglePlaceTerminal: AnyObject, Sendable {
    func togglePlaceViewport() -> (top: Int, visible: Int, total: Int, atBottom: Bool)?
    func togglePlaceRead(fromViewportTop: Bool, throughViewportBottom: Bool) -> (screen: String, columns: Int)?
    func togglePlaceScroll(toRow row: Int?)

    /// The newest bytes the terminal sent its program, and whether older ones were dropped (the draft's input line).
    var toggleDraftTyped: (bytes: [UInt8], truncated: Bool) { get }
    /// Nothing sent since the session started: no draft, and no need to read further.
    var toggleDraftNothingTyped: Bool { get }
    /// The active rows (the screen's bottom, wherever the viewport is), one line per row.
    func toggleDraftScreen() -> String?
    /// Pastes `text` as the person would: Ghostty brackets it when the program asked for that.
    func toggleDraftPaste(_ text: String)
    /// Sends `bytes` as typed (the DELs that erase a carried draft), recorded like every key.
    func toggleDraftSend(_ bytes: [UInt8])
}

/// A face with no draft to carry (a stand-in in a test of the place alone): the swap moves none.
extension TogglePlaceTerminal {
    public var toggleDraftTyped: (bytes: [UInt8], truncated: Bool) { ([], false) }
    public var toggleDraftNothingTyped: Bool { true }
    public func toggleDraftScreen() -> String? { nil }
    public func toggleDraftPaste(_ text: String) {}
    public func toggleDraftSend(_ bytes: [UInt8]) {}
}

/// The chat face of a pair, as a swap reads and moves it (``AgentPaneTogglePlace``, conformed in the App).
@MainActor
public protocol TogglePlaceChat: AnyObject, Sendable {
    var togglePlaceAtLatest: Bool { get }
    func togglePlacePrompts(by deadline: ContinuousClock.Instant) async -> (prompts: [String], at: Int?)?
    @discardableResult func togglePlaceShow(prompt index: Int?, by deadline: ContinuousClock.Instant) async -> Bool

    /// The composer holds text or chips, as the page last reported: no page call.
    var toggleDraftFilled: Bool { get }
    /// The composer's text when it can leave as text; nil when it cannot, or the page does not answer by `deadline`.
    func toggleDraft(by deadline: ContinuousClock.Instant) async -> String?
    /// Empties the composer if it still holds exactly `text`.
    func toggleDraftTake(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool
    /// Puts `text` in an empty composer.
    func toggleDraftPut(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool
}

/// A face with no draft to carry (a stand-in in a test of the place alone): the swap moves none.
extension TogglePlaceChat {
    public var toggleDraftFilled: Bool { false }
    public func toggleDraft(by deadline: ContinuousClock.Instant) async -> String? { nil }
    public func toggleDraftTake(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool { false }
    public func toggleDraftPut(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool { false }
}

/// Moves the face about to show to the turn the other one shows, before it shows, so the swap's
/// first frame is already there: no jump after it. Nothing to move (both at their latest) asks
/// nothing of the page, so that swap stays a plain tab selection.
///
/// The cost stays flat however long the session: the swap waits on the page at most `budget` in
/// all, and reads at most `rows` screen rows. Ghostty addresses no window of a long history but
/// from or through the viewport, so the hidden terminal's viewport is moved to the window's top
/// to read the newest `rows`; the shown one is read on whichever side of its viewport fits.
@MainActor
public struct TerminalChatPlacing {
    public static let budget: Duration = .milliseconds(60)
    public static let rows = 20_000

    public let chat: (any TogglePlaceChat)?
    public let terminal: (any TogglePlaceTerminal)?
    let rules: TogglePlaceRules
    let rowCap: Int

    public init(chat: (any TogglePlaceChat)?, terminal: (any TogglePlaceTerminal)?, rules: WindowRules = WindowRules(),
                rows: Int = Self.rows) {
        self.chat = chat
        self.terminal = terminal
        self.rules = TogglePlaceRules(rules: rules)
        rowCap = rows
    }

    /// Whether the swap moves nothing: a face is missing, or both are at their latest.
    public var settled: Bool {
        guard let chat, let viewport = terminal?.togglePlaceViewport() else { return true }
        return chat.togglePlaceAtLatest && viewport.atBottom
    }

    /// Before the terminal shows (it is hidden): to the row of the chat's turn, or its newest rows. What it reads and
    /// where it scrolls are Rust's (cmux-window-rules `tabs::place::terminal_read`, `terminal_scroll`).
    public func placeTerminal(by deadline: ContinuousClock.Instant = ContinuousClock.now + TerminalChatPlacing.budget) async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        guard let read = await chat.togglePlacePrompts(by: deadline),
              let plan = rules.terminalRead(.init(at: read.at, total: viewport.total, rows: rowCap)) else { return }
        guard case let .screen(base, fromViewportTop) = plan else { return terminal.togglePlaceScroll(toRow: nil) }
        if fromViewportTop { terminal.togglePlaceScroll(toRow: base) }
        let scroll = terminal.togglePlaceRead(fromViewportTop: fromViewportTop, throughViewportBottom: false).flatMap { screen in
            rules.terminalScroll(.init(prompts: read.prompts, at: read.at, screen: screen.screen, base: base, columns: screen.columns,
                                       top: viewport.top, atBottom: viewport.atBottom))
        }
        switch scroll {
        case .row(let row)?: terminal.togglePlaceScroll(toRow: row)
        case .latest?: terminal.togglePlaceScroll(toRow: nil)
        case .keep?: break
        // No screen or no answer: back where it was, when the read moved it.
        case nil: if fromViewportTop { terminal.togglePlaceScroll(toRow: viewport.atBottom ? nil : viewport.top) }
        }
    }

    /// Before the chat shows (the terminal still shows): to the turn of the terminal's top row, or its latest message.
    /// What it reads and shows are Rust's (`tabs::place::chat_read`, `chat_show`).
    public func placeChat(by deadline: ContinuousClock.Instant = ContinuousClock.now + TerminalChatPlacing.budget) async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        let facts = TogglePlaceRules.ChatReadFacts(top: viewport.top, visible: viewport.visible, total: viewport.total,
                                                   atBottom: viewport.atBottom, atLatest: chat.togglePlaceAtLatest, rows: rowCap)
        switch rules.chatRead(facts) {
        case .latest(let show)?: if show { await chat.togglePlaceShow(prompt: nil, by: deadline) }
        case let .screen(base, fromViewportTop, throughViewportBottom)?:
            guard let read = await chat.togglePlacePrompts(by: deadline),
                  let screen = terminal.togglePlaceRead(fromViewportTop: fromViewportTop, throughViewportBottom: throughViewportBottom)
            else { return }
            let show = rules.chatShow(.init(prompts: read.prompts, screen: screen.screen, base: base, columns: screen.columns,
                                            top: viewport.top, atBottom: false, at: read.at))
            switch show {
            case .latest?: await chat.togglePlaceShow(prompt: nil, by: deadline)
            case .turn(let index)?: await chat.togglePlaceShow(prompt: index, by: deadline)
            case .stay?, nil: break
            }
        case .stay?, nil: break
        }
    }
}
