import CmuxNextWindowRules
import Foundation
import Testing

/// Toggle Terminal and Chat lands at the same turn in the other view, both ways (Leo, 2026-11-12:
/// two live views of one session). The match is Rust's (cmux-window-rules `tabs::place`, with its
/// cases); these hold ``TerminalChatPlacing`` moving the face about to show, over the FFI.
@MainActor @Suite
struct TerminalChatPlaceTests {
    /// A resumed Claude Code screen: each prompt echoed after `> `.
    static let screen = ["> fix the login bug", "", "⏺ In auth.rs.", "", "> now add a test", "", "⏺ Added.", "", "> "]
        .joined(separator: "\n")
    static let prompts = ["fix the login bug", "now add a test"]

    /// A terminal of `rows` screen rows with a viewport of `visible` rows at `top`.
    final class Terminal: TogglePlaceTerminal {
        let rows: [String], visible: Int
        var top: Int
        var scrolls: [Int?] = []
        /// Each read's rows (its first and its count).
        var reads: [ClosedRange<Int>] = []

        init(screen: String = TerminalChatPlaceTests.screen, visible: Int = 5, top: Int? = nil) {
            rows = screen.components(separatedBy: "\n")
            self.visible = visible
            self.top = top ?? max(0, rows.count - visible)
        }

        var bottom: Int { max(0, rows.count - visible) }
        var atBottom: Bool { top >= bottom }

        func togglePlaceViewport() -> (top: Int, visible: Int, total: Int, atBottom: Bool)? { (top, visible, rows.count, atBottom) }
        func togglePlaceRead(fromViewportTop: Bool, throughViewportBottom: Bool) -> (screen: String, columns: Int)? {
            let first = fromViewportTop ? top : 0, last = throughViewportBottom ? min(rows.count, top + visible) - 1 : rows.count - 1
            reads.append(first...last)
            return (rows[first...last].joined(separator: "\n"), 80)
        }
        func togglePlaceScroll(toRow row: Int?) {
            scrolls.append(row)
            top = min(row ?? bottom, bottom)
        }
    }

    final class Chat: TogglePlaceChat {
        var at: Int?
        var shows: [Int?] = []
        var reads = 0

        init(at: Int?) { self.at = at }

        var togglePlaceAtLatest: Bool { at == nil }
        func togglePlacePrompts(by deadline: ContinuousClock.Instant) async -> (prompts: [String], at: Int?)? {
            reads += 1
            return (TerminalChatPlaceTests.prompts, at)
        }
        func togglePlaceShow(prompt index: Int?, by deadline: ContinuousClock.Instant) async -> Bool {
            shows.append(index)
            at = index
            return true
        }
    }

    @Test func theTerminalShowsAtTheChatsTurn() async {
        let chat = Chat(at: 0), terminal = Terminal()
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(!placing.settled)
        await placing.placeTerminal()
        #expect(terminal.scrolls == [0])
        let other = Terminal(top: 0)
        await TerminalChatPlacing(chat: Chat(at: 1), terminal: other).placeTerminal()
        #expect(other.scrolls == [4])
    }

    @Test func theChatShowsAtTheTerminalsTurn() async {
        let chat = Chat(at: nil), terminal = Terminal(top: 2)
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
        #expect(chat.shows == [0])
        // The terminal back at its newest rows: the chat at its latest message.
        terminal.top = terminal.bottom
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
        #expect(chat.shows == [0, nil])
    }

    @Test func bothAtTheirLatestMoveNothingAndAskThePageNothing() async {
        let chat = Chat(at: nil), terminal = Terminal()
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(placing.settled)
        await placing.placeTerminal()
        await placing.placeChat()
        #expect(chat.reads == 0 && chat.shows.isEmpty && terminal.scrolls.isEmpty && terminal.reads.isEmpty)
    }

    @Test func aChatAtItsLatestBringsTheTerminalToItsNewestRows() async {
        // The page is asked even though the kept place says latest: that place can lag a quick swap back.
        let chat = Chat(at: nil), terminal = Terminal(top: 0)
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeTerminal()
        #expect(terminal.scrolls == [nil])
        #expect(chat.reads == 1 && terminal.reads.isEmpty)
    }

    @Test func tenSwapsOnAScrolledUpTurnKeepIt() async {
        let chat = Chat(at: 0), terminal = Terminal()
        for _ in 0..<10 {
            await TerminalChatPlacing(chat: chat, terminal: terminal).placeTerminal()
            #expect(terminal.top == 0)
            await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
            #expect(chat.at == 0)
        }
        // The chat never moved: every swap back found it on the terminal's turn.
        #expect(chat.shows.isEmpty)
    }

    @Test func aMissingFaceMovesNothing() async {
        let chat = Chat(at: 0)
        let placing = TerminalChatPlacing(chat: chat, terminal: nil)
        #expect(placing.settled)
        await placing.placeTerminal()
        await placing.placeChat()
        #expect(chat.reads == 0)
    }

    /// 40 rows of older history, then the two turns, then one more row: 50 rows.
    static let longScreen = (Array(repeating: "older output", count: 40) + screen.components(separatedBy: "\n") + [""])
        .joined(separator: "\n")

    @Test func aLongHistoryIsReadOnlyAsFarAsTheCap() async {
        // To the hidden terminal: its viewport moves to the newest 10 rows' top to read just those.
        let terminal = Terminal(screen: Self.longScreen)
        await TerminalChatPlacing(chat: Chat(at: 1), terminal: terminal, rows: 10).placeTerminal()
        #expect(terminal.reads == [40...49])
        #expect(terminal.scrolls == [40, 44])
        // To the chat with the shown terminal on turn 1: read from its viewport's top, never above it.
        let shown = Terminal(screen: Self.longScreen, top: 44), chat = Chat(at: nil)
        await TerminalChatPlacing(chat: chat, terminal: shown, rows: 10).placeChat()
        #expect(shown.reads == [44...49])
        #expect(chat.shows == [1] && shown.scrolls.isEmpty)
        // Neither side of the viewport fits: nothing is read, nothing moves.
        let far = Terminal(screen: Self.longScreen, top: 20), stays = Chat(at: nil)
        await TerminalChatPlacing(chat: stays, terminal: far, rows: 10).placeChat()
        #expect(far.reads.isEmpty && stays.shows.isEmpty)
    }

    @Test func aTurnTheWindowLacksPutsTheHiddenTerminalBack() async {
        // Turn 0's prompt is above the newest 5 rows: the terminal goes back to its newest rows.
        let terminal = Terminal(screen: Self.longScreen)
        await TerminalChatPlacing(chat: Chat(at: 0), terminal: terminal, rows: 5).placeTerminal()
        #expect(terminal.scrolls == [45, nil])
        #expect(terminal.atBottom)
    }
}
