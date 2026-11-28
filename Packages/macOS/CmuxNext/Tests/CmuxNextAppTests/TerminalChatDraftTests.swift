import CmuxNextWindowRules
import Foundation
import Testing

/// Toggle Terminal and Chat carries the unsent draft, both ways (Leo, 2026-11-12: two live views of
/// one session, instant both ways). What moves is Rust's (cmux-window-rules `tabs::draft`, with its
/// cases); these hold ``TerminalChatPlacing`` moving it over the FFI: into the face about to show,
/// never merged with a draft there, and out of the other face only once the new one holds it.
@MainActor @Suite
struct TerminalChatDraftTests {
    /// What both faces did, in order.
    final class Log {
        var events: [String] = []
    }

    /// A terminal at its newest rows, with what it sent its program and its bottom rows.
    final class Terminal: TogglePlaceTerminal {
        let log: Log
        var typed: [UInt8]
        var truncated = false
        /// The bottom rows: Claude Code's input box with `shows` in it.
        var shows: String
        var pastes: [String] = []
        var sends: [[UInt8]] = []
        var screenReads = 0

        init(_ log: Log, typed: String = "", shows: String = "") {
            self.log = log
            self.typed = Array(typed.utf8)
            self.shows = shows
        }

        func togglePlaceViewport() -> (top: Int, visible: Int, total: Int, atBottom: Bool)? { (0, 5, 5, true) }
        func togglePlaceRead(fromViewportTop: Bool, throughViewportBottom: Bool) -> (screen: String, columns: Int)? { nil }
        func togglePlaceScroll(toRow row: Int?) {}
        var toggleDraftTyped: (bytes: [UInt8], truncated: Bool) { (typed, truncated) }
        var toggleDraftNothingTyped: Bool { typed.isEmpty && !truncated }
        func toggleDraftScreen() -> String? {
            screenReads += 1
            return "⏺ Done.\n\n╭────────────────────────╮\n│ > \(shows) │\n╰────────────────────────╯\n  ? for shortcuts"
        }
        /// As Ghostty does for a program that asked for bracketed paste: the bytes go out bracketed.
        func toggleDraftPaste(_ text: String) {
            log.events.append("paste")
            pastes.append(text)
            typed += Array("\u{1b}[200~\(text)\u{1b}[201~".utf8)
            shows = text
        }
        func toggleDraftSend(_ bytes: [UInt8]) {
            log.events.append("erase")
            sends.append(bytes)
            typed += bytes
            shows = ""
        }
    }

    /// A chat at its latest message, with `text` (and maybe chips) in its composer.
    final class Chat: TogglePlaceChat {
        let log: Log
        var text: String
        var chips = false
        /// The page answers a write in time (false: it answers too late, or the person typed first).
        var answers = true
        var reads = 0
        /// What happens while the page answers: the person typing in the still shown terminal.
        var whileAnswering: (() -> Void)?

        init(_ log: Log, text: String = "") {
            self.log = log
            self.text = text
        }

        var togglePlaceAtLatest: Bool { true }
        func togglePlacePrompts(by deadline: ContinuousClock.Instant) async -> (prompts: [String], at: Int?)? { nil }
        func togglePlaceShow(prompt index: Int?, by deadline: ContinuousClock.Instant) async -> Bool { false }
        var toggleDraftFilled: Bool { !text.isEmpty || chips }
        func toggleDraft(by deadline: ContinuousClock.Instant) async -> String? {
            reads += 1
            return chips || text.isEmpty ? nil : text
        }
        func toggleDraftTake(_ taken: String, by deadline: ContinuousClock.Instant) async -> Bool {
            guard answers, text == taken else { return false }
            log.events.append("take")
            text = ""
            return true
        }
        func toggleDraftPut(_ put: String, by deadline: ContinuousClock.Instant) async -> Bool {
            guard answers, text.isEmpty, !chips else { return false }
            log.events.append("put")
            whileAnswering?()
            text = put
            return true
        }
    }

    static let del: UInt8 = 0x7f

    @Test func theComposersDraftGoesIntoTheTerminalsEmptyInput() async {
        let log = Log(), chat = Chat(log, text: "now add a test"), terminal = Terminal(log, typed: "fix it\r")
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(!placing.settled(toTerminal: true))
        await placing.swap(toTerminal: true)
        #expect(terminal.pastes == ["now add a test"])
        #expect(chat.text.isEmpty)
        // Pasted first, then taken: a late answer leaves it in both, never in neither.
        #expect(log.events == ["paste", "take"])
    }

    @Test func theTerminalsDraftGoesIntoTheEmptyComposerThenLeavesTheTerminal() async {
        let log = Log(), chat = Chat(log), terminal = Terminal(log, typed: "fix it\rship it", shows: "ship it")
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(!placing.settled(toTerminal: false))
        await placing.swap(toTerminal: false)
        #expect(chat.text == "ship it")
        #expect(log.events == ["put", "erase"])
        // One DEL a character, no more: a spare one would take a key still on its way.
        #expect(terminal.sends.count == 1 && terminal.sends[0] == [UInt8](repeating: Self.del, count: 7))
    }

    @Test func twoDraftsAreNeverMerged() async {
        let log = Log(), chat = Chat(log, text: "the chat's"), terminal = Terminal(log, typed: "the terminal's", shows: "the terminal's")
        // To the terminal: its input holds a draft, so the composer keeps its own.
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: true)
        #expect(terminal.pastes.isEmpty && chat.text == "the chat's")
        // To the chat: the composer holds one, so the terminal keeps its own, read without the page.
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(placing.settled(toTerminal: false))
        await placing.swap(toTerminal: false)
        #expect(log.events.isEmpty && terminal.screenReads == 0)
    }

    @Test func typingTheRulesCannotFollowCarriesNothing() async {
        // An arrow moved the cursor: the input is not known.
        let log = Log(), chat = Chat(log), terminal = Terminal(log, typed: "ship\u{1b}[D it", shows: "shi pit")
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(placing.settled(toTerminal: false))
        await placing.swap(toTerminal: false)
        #expect(chat.text.isEmpty && terminal.sends.isEmpty)
        // Nor is it known to be empty, so the composer's draft stays in the chat.
        chat.text = "from the chat"
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: true)
        #expect(terminal.pastes.isEmpty && chat.text == "from the chat")
        // Bytes that start mid-draft, or a draft the screen does not show (a dialog took the keys).
        let cut = Terminal(log, typed: "ship it", shows: "ship it")
        cut.truncated = true
        #expect(TerminalChatPlacing(chat: Chat(log), terminal: cut).settled(toTerminal: false))
        let dialog = Terminal(log, typed: "ship it", shows: "1. Yes  2. No")
        #expect(TerminalChatPlacing(chat: Chat(log), terminal: dialog).settled(toTerminal: false))
        #expect(log.events.isEmpty)
    }

    @Test func theTerminalIsErasedOnlyOnceTheComposerTookTheDraft() async {
        let log = Log(), chat = Chat(log), terminal = Terminal(log, typed: "ship it", shows: "ship it")
        chat.answers = false
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: false)
        #expect(terminal.sends.isEmpty && chat.text.isEmpty)
        // A composer that cannot take it as text (chips) gives nothing to the terminal either.
        let chips = Chat(log, text: "see this")
        chips.chips = true
        await TerminalChatPlacing(chat: chips, terminal: Terminal(log)).swap(toTerminal: true)
        #expect(chips.text == "see this" && log.events.isEmpty)
    }

    @Test func aKeyTypedWhileThePageAnswersIsNeverErased() async {
        // The terminal still shows during the swap: an `x` typed then lands after the draft, where DELs would take it.
        let log = Log(), chat = Chat(log), terminal = Terminal(log, typed: "ship it", shows: "ship it")
        chat.whileAnswering = { terminal.typed += Array("x".utf8) }
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: false)
        #expect(chat.text == "ship it" && terminal.sends.isEmpty)
        #expect(log.events == ["put"])
    }

    @Test func noPasteWithoutTimeForTheTake() async {
        // The page's read answered with too little of the budget left for the take: the draft stays in the chat alone.
        let log = Log(), chat = Chat(log, text: "ship it"), terminal = Terminal(log)
        await TerminalChatPlacing(chat: chat, terminal: terminal).carryToTerminal(by: .now + .milliseconds(5))
        #expect(terminal.pastes.isEmpty && chat.text == "ship it" && log.events.isEmpty)
    }

    @Test func wordsTheBytesNeverSawStayPut() async {
        // A draft from before this app attached (a relaunch, another client): the box shows more than the bytes.
        let log = Log(), chat = Chat(log, text: "add tests"), terminal = Terminal(log, shows: "refactor auth")
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: true)
        #expect(terminal.pastes.isEmpty && chat.text == "add tests")
        chat.text = ""
        terminal.typed = Array(" now".utf8)
        terminal.shows = "refactor auth now"
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: false)
        #expect(chat.text.isEmpty && terminal.sends.isEmpty && log.events.isEmpty)
        // Several lines stay in the chat: the app cannot read whether the program brackets a paste.
        let lines = Chat(log, text: "one\ntwo")
        await TerminalChatPlacing(chat: lines, terminal: Terminal(log)).swap(toTerminal: true)
        #expect(lines.text == "one\ntwo" && log.events.isEmpty)
    }

    @Test func noDraftAnywhereIsAPlainTabSelection() async {
        let log = Log(), chat = Chat(log), terminal = Terminal(log)
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(placing.settled(toTerminal: true) && placing.settled(toTerminal: false))
        // Typed and sent: still nothing to carry, and the composer is never asked.
        terminal.typed = Array("fix it\r".utf8)
        #expect(placing.settled(toTerminal: true) && placing.settled(toTerminal: false))
        #expect(chat.reads == 0 && log.events.isEmpty)
    }

    @Test func aDraftCarriedBothWaysComesBackWhole() async {
        let log = Log(), chat = Chat(log, text: "ship it"), terminal = Terminal(log, typed: "fix it\r")
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: true)
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: false)
        #expect(chat.text == "ship it")
        #expect(log.events == ["paste", "take", "put", "erase"])
        // The DELs left the terminal's input empty: the next draft from the chat goes in again.
        chat.text = "and test it"
        await TerminalChatPlacing(chat: chat, terminal: terminal).swap(toTerminal: true)
        #expect(terminal.pastes == ["ship it", "and test it"])
    }
}
