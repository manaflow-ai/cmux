import Foundation

/// The draft half of a swap: it moves within the swap's one budget, before the face about to show
/// shows, so that face's first frame already holds it. With an empty composer and nothing typed in
/// the terminal, nothing is read and the swap stays a plain tab selection.
extension TerminalChatPlacing {
    /// Whether the swap moves nothing, neither place nor draft, read without the page.
    public func settled(toTerminal: Bool) -> Bool {
        settled && draftSettled(toTerminal: toTerminal)
    }

    /// Whether the swap carries no draft, read without the page: to the terminal, the composer
    /// holds nothing; to the chat, the composer holds something or the terminal's input carries
    /// nothing Rust can be sure of.
    public func draftSettled(toTerminal: Bool) -> Bool {
        guard let chat, let terminal else { return true }
        if toTerminal { return !chat.toggleDraftFilled }
        return chat.toggleDraftFilled || terminal.toggleDraftNothingTyped || chatDraft() == nil
    }

    /// The whole swap's move before `toTerminal`'s face shows: the draft first (a paste brings the
    /// terminal to its newest rows), then the place, all within one ``budget``.
    public func swap(toTerminal: Bool) async {
        let deadline = ContinuousClock.now + Self.budget
        let places = !settled
        if toTerminal {
            await carryToTerminal(by: deadline)
            if places { await placeTerminal(by: deadline) }
        } else {
            await carryToChat(by: deadline)
            if places { await placeChat(by: deadline) }
        }
    }

    /// Before the terminal shows: the composer's draft is pasted into the terminal's empty input,
    /// then the composer gives it up (the other order could lose it to a late answer).
    public func carryToTerminal(by deadline: ContinuousClock.Instant) async {
        guard let chat, let terminal, chat.toggleDraftFilled, let text = await chat.toggleDraft(by: deadline),
              // Too late for the take to answer: pasting now would leave the draft in both.
              ContinuousClock.now + Self.takeRoom < deadline else { return }
        let typed = terminal.toggleDraftTyped
        guard let screen = terminal.toggleDraftScreen(),
              case .paste(let paste)? = draftRules.draftToTerminal(.init(chat: text, typed: typed.bytes, truncated: typed.truncated, screen: screen))
        else { return }
        terminal.toggleDraftPaste(paste)
        _ = await chat.toggleDraftTake(text, by: deadline)
    }

    /// Before the chat shows: the terminal's draft goes into the empty composer, and only once the
    /// composer holds it do the DELs erase it from the terminal. A key typed in the terminal while
    /// the page answered lands after the draft, where the DELs would take it: then the terminal
    /// keeps its input, and the draft is in both.
    public func carryToChat(by deadline: ContinuousClock.Instant) async {
        guard let terminal, let carry = chatDraft(), await chat?.toggleDraftPut(carry.text, by: deadline) == true,
              terminal.toggleDraftTyped == carry.typed else { return }
        terminal.toggleDraftSend([UInt8](repeating: 0x7f, count: carry.erase))
    }

    private var draftRules: ToggleDraftRules { ToggleDraftRules(rules: rules.rules) }

    /// What a carry to the terminal leaves the page's take at least.
    static let takeRoom: Duration = .milliseconds(20)

    /// Rust's answer for the terminal's draft going to the chat, with the bytes it read; nil for none.
    private func chatDraft() -> (text: String, erase: Int, typed: (bytes: [UInt8], truncated: Bool))? {
        guard let chat, let terminal, !chat.toggleDraftFilled, !terminal.toggleDraftNothingTyped,
              let screen = terminal.toggleDraftScreen() else { return nil }
        let typed = terminal.toggleDraftTyped
        let facts = ToggleDraftRules.ToChatDraft(typed: typed.bytes, truncated: typed.truncated, screen: screen, composerEmpty: true)
        guard case .carry(let text, let erase)? = draftRules.draftToChat(facts) else { return nil }
        return (text, erase, typed)
    }
}
