import CmuxNextWindowRules
import Foundation
import Observation
import Testing

/// Toggle Terminal and Chat's approval (Leo, 2026-11-12: two live views of one session): while the
/// terminal drives, its harness's dialog shows in the chat and a click picks that option in the
/// terminal. The parse and the keys are Rust's (cmux-window-rules `tabs::approval`, with its cases);
/// these hold ``TerminalChatApproving`` reading and answering over the FFI.
@MainActor @Suite
struct TerminalChatApprovalTests {
    static let dialog = [
        " Bash command", "", "   touch /tmp/w4i-perm", "   Create an empty marker file", "",
        " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for touch commands in /private/tmp",
        "   3. No, and tell Claude what to do differently (esc)", "", " Esc to cancel · Tab to amend",
    ].joined(separator: "\n")

    @MainActor @Observable final class Terminal: TerminalApprovalTerminal {
        var blocked = false
        var screen: String? = TerminalChatApprovalTests.dialog
        @ObservationIgnored var reads = 0
        @ObservationIgnored var pressed: [[String]] = []
        @ObservationIgnored var refuses = false

        var approvalBlocked: Bool { blocked }
        func approvalScreen() async -> String? { reads += 1; return screen }
        func approvalPress(_ keys: [String]) async -> Bool {
            guard !refuses else { return false }
            pressed.append(keys)
            return true
        }
    }

    @MainActor final class Chat: TerminalApprovalChat {
        var shown: [WindowRules.TerminalApproval?] = []
        var answer: (@MainActor (Int, String, String) async -> Bool)?

        func showTerminalApproval(_ approval: WindowRules.TerminalApproval?, answer: @escaping @MainActor (Int, String, String) async -> Bool) {
            shown.append(approval)
            self.answer = answer
        }
    }

    @Test func aBlockedTerminalsDialogShowsInTheChatAndAClickPicksItsOption() async throws {
        let terminal = Terminal(), chat = Chat()
        let approving = TerminalChatApproving(terminal: terminal, chat: chat)
        await approving.refresh()
        #expect(chat.shown.isEmpty, "a terminal that does not wait on the person is not read")
        #expect(terminal.reads == 0)
        terminal.blocked = true
        await approving.refresh()
        let shown = try #require(chat.shown.last ?? nil)
        #expect(shown.question == "Do you want to proceed?")
        #expect(shown.command == "touch /tmp/w4i-perm")
        #expect(shown.options.map(\.key) == [1, 2, 3])
        #expect(shown.options.map(\.kind) == ["allow_once", "allow_always", "reject_once"])
        // The third option: two down from the cursor, then Enter; the card goes at once.
        let answered = await chat.answer?(3, "No, and tell Claude what to do differently", "Do you want to proceed?")
        #expect(answered == true)
        #expect(terminal.pressed == [["down", "down", "enter"]])
        #expect(chat.shown.count == 2 && chat.shown.last! == nil)
    }

    @Test func aClickTypesNothingOnceTheTerminalAsksSomethingElse() async throws {
        let terminal = Terminal(), chat = Chat()
        terminal.blocked = true
        let approving = TerminalChatApproving(terminal: terminal, chat: chat)
        await approving.refresh()
        // Answered in the terminal meanwhile: the prompt box is back.
        terminal.screen = "⏺ Done.\n\n❯ \n"
        let answered = await chat.answer?(1, "Yes", "Do you want to proceed?")
        #expect(answered == false)
        #expect(terminal.pressed.isEmpty)
        #expect(chat.shown.last! == nil, "the stale card is taken down")
        // A refused key press keeps the card.
        terminal.screen = Self.dialog
        await approving.refresh()
        terminal.refuses = true
        #expect(await chat.answer?(1, "Yes", "Do you want to proceed?") == false)
        #expect(chat.shown.last! != nil)
    }

    /// The watch reads again on each change of the agent state, with no poll.
    @Test func eachChangeOfTheAgentStateReadsAgain() async throws {
        let terminal = Terminal(), chat = Chat()
        let approving = TerminalChatApproving(terminal: terminal, chat: chat)
        approving.start()
        terminal.blocked = true
        try await wait { chat.shown.last.flatMap { $0 } != nil }
        terminal.blocked = false
        try await wait { chat.shown.count == 2 && chat.shown.last! == nil }
        approving.stop()
        terminal.blocked = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(chat.shown.count == 2, "a stopped watch reads nothing")
    }

    private func wait(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            // wakeup-allow: a test waits for the watch's own hop
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(done())
    }
}
