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

    final class Terminal: TogglePlaceTerminal {
        var top: Int, atBottom: Bool
        var scrolls: [Int?] = []
        var screenReads = 0

        init(top: Int = 4, atBottom: Bool = true) {
            self.top = top
            self.atBottom = atBottom
        }

        func togglePlaceViewport() -> (top: Int, atBottom: Bool)? { (top, atBottom) }
        func togglePlaceScreen() -> (screen: String, columns: Int)? {
            screenReads += 1
            return (TerminalChatPlaceTests.screen, 80)
        }
        func togglePlaceScroll(toRow row: Int?) {
            scrolls.append(row)
            top = row ?? 4
            atBottom = row == nil
        }
    }

    final class Chat: TogglePlaceChat {
        var at: Int?
        var shows: [Int?] = []
        var reads = 0

        init(at: Int?) { self.at = at }

        var togglePlaceAtLatest: Bool { at == nil }
        func togglePlacePrompts() async -> (prompts: [String], at: Int?)? {
            reads += 1
            return (TerminalChatPlaceTests.prompts, at)
        }
        func togglePlaceShow(prompt index: Int?) async -> Bool {
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
        let second = Chat(at: 1), other = Terminal()
        await TerminalChatPlacing(chat: second, terminal: other).placeTerminal()
        #expect(other.scrolls.isEmpty) // the turn's row 4 is already the top: nothing moves
    }

    @Test func theChatShowsAtTheTerminalsTurn() async {
        let chat = Chat(at: nil), terminal = Terminal(top: 2, atBottom: false)
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
        #expect(chat.shows == [0])
        // The terminal back at its newest rows: the chat at its latest message.
        terminal.atBottom = true
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
        #expect(chat.shows == [0, nil])
    }

    @Test func bothAtTheirLatestMoveNothingAndAskThePageNothing() async {
        let chat = Chat(at: nil), terminal = Terminal()
        let placing = TerminalChatPlacing(chat: chat, terminal: terminal)
        #expect(placing.settled)
        await placing.placeTerminal()
        await placing.placeChat()
        #expect(chat.reads == 0 && chat.shows.isEmpty && terminal.scrolls.isEmpty && terminal.screenReads == 0)
    }

    @Test func aChatAtItsLatestBringsTheTerminalToItsNewestRows() async {
        let chat = Chat(at: nil), terminal = Terminal(top: 0, atBottom: false)
        await TerminalChatPlacing(chat: chat, terminal: terminal).placeTerminal()
        #expect(terminal.scrolls == [nil])
        #expect(chat.reads == 0)
    }

    @Test func tenSwapsOnAScrolledUpTurnKeepIt() async {
        let chat = Chat(at: 0), terminal = Terminal()
        for _ in 0..<10 {
            await TerminalChatPlacing(chat: chat, terminal: terminal).placeTerminal()
            #expect(terminal.top == 0)
            await TerminalChatPlacing(chat: chat, terminal: terminal).placeChat()
            #expect(chat.at == 0)
        }
        // The first swap moved the terminal; every later one found both already there.
        #expect(terminal.scrolls == [0])
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
}
