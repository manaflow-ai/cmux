import Foundation

/// The terminal face of a pair, as a swap reads and moves it (`TerminalSession+TogglePlace`, conformed in the App).
@MainActor
public protocol TogglePlaceTerminal: AnyObject, Sendable {
    func togglePlaceViewport() -> (top: Int, visible: Int, total: Int, atBottom: Bool)?
    func togglePlaceRead(fromViewportTop: Bool, throughViewportBottom: Bool) -> (screen: String, columns: Int)?
    func togglePlaceScroll(toRow row: Int?)
}

/// The chat face of a pair, as a swap reads and moves it (``AgentPaneTogglePlace``, conformed in the App).
@MainActor
public protocol TogglePlaceChat: AnyObject, Sendable {
    var togglePlaceAtLatest: Bool { get }
    func togglePlacePrompts(by deadline: ContinuousClock.Instant) async -> (prompts: [String], at: Int?)?
    @discardableResult func togglePlaceShow(prompt index: Int?, by deadline: ContinuousClock.Instant) async -> Bool
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

    /// Before the terminal shows (it is hidden): to the row of the chat's turn, or its newest rows.
    public func placeTerminal() async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        let deadline = ContinuousClock.now + Self.budget
        guard let read = await chat.togglePlacePrompts(by: deadline) else { return }
        guard read.at != nil else { return terminal.togglePlaceScroll(toRow: nil) }
        // The newest `rowCap` rows: all of a short screen, else read with the viewport at their top.
        let base = max(0, viewport.total - rowCap)
        if base > 0 { terminal.togglePlaceScroll(toRow: base) }
        let place = terminal.togglePlaceRead(fromViewportTop: base > 0, throughViewportBottom: false).flatMap { screen in
            rules.terminalPlace(.init(prompts: read.prompts, at: read.at, screen: screen.screen, base: base, columns: screen.columns))
        }
        switch place {
        case .row(let row)?: terminal.togglePlaceScroll(toRow: row)
        case .latest?: terminal.togglePlaceScroll(toRow: nil)
        // Nothing to land on: back where it was.
        case .stay?, nil: if base > 0 { terminal.togglePlaceScroll(toRow: viewport.atBottom ? nil : viewport.top) }
        }
    }

    /// Before the chat shows (the terminal still shows): to the turn of the terminal's top row, or
    /// its latest message.
    public func placeChat() async {
        guard let chat, let terminal, let viewport = terminal.togglePlaceViewport() else { return }
        let deadline = ContinuousClock.now + Self.budget
        if viewport.atBottom {
            if !chat.togglePlaceAtLatest { await chat.togglePlaceShow(prompt: nil, by: deadline) }
            return
        }
        guard let read = await chat.togglePlacePrompts(by: deadline) else { return }
        // Through the viewport when what is above it fits, else from its top; neither: it stays.
        let fromTop = viewport.top + viewport.visible > rowCap
        guard !fromTop || viewport.total - viewport.top <= rowCap,
              let screen = terminal.togglePlaceRead(fromViewportTop: fromTop, throughViewportBottom: !fromTop) else { return }
        let facts = TogglePlaceRules.ToChatPlace(prompts: read.prompts, screen: screen.screen, base: fromTop ? viewport.top : 0,
                                            columns: screen.columns, top: viewport.top, atBottom: false)
        switch rules.chatPlace(facts) {
        case .latest?: if read.at != nil { await chat.togglePlaceShow(prompt: nil, by: deadline) }
        case .turn(let index)? where index != read.at: await chat.togglePlaceShow(prompt: index, by: deadline)
        case .turn?, .stay?, nil: break
        }
    }
}
