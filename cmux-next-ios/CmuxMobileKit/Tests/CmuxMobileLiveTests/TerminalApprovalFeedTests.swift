import CmuxMobileAgentChat
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileLive

/// The Feed card of a terminal agent's approval (a Claude Code permission prompt): Allow once /
/// Deny inline, answered by one key typed on that terminal only while it shows this approval.
@MainActor
@Suite struct TerminalApprovalFeedTests {
    nonisolated static let approval = #"{"harness":"claude","tool":"Bash","command":"mkdir -p out && touch out/a.txt","description":"Create the out folder"}"#

    static func row(approval: String? = TerminalApprovalFeedTests.approval) -> String {
        let extra = approval.map { #","approval":\#($0)"# } ?? ""
        return #"{"id":"ntf_7","title":"Claude needs approval","subtitle":null,"body":"Bash","level":"warning","terminal_id":"term_x","surface":1,"created_at_ms":5000000,"source":"agent","acknowledged":false\#(extra)}"#
    }

    /// Claude Code 2.1.328's approval screen, as read live (verify/push-matrix-terminal-questions.md).
    nonisolated static let rule = String(repeating: "\u{2500}", count: 60)

    /// The dialog of `command` under a transcript that shows `transcript` (an earlier call).
    static func screen(command: String = "mkdir -p out && touch out/a.txt", transcript: String = "ls -la") -> String {
        """
        ⏺ Running the command
          ⎿  $ \(transcript)
        \(rule)
         Bash command
         Create the out folder
         \(command)
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for mkdir and touch commands in /tmp/x
           3. Yes, and switch to auto mode · auto mode handles these prompts for you
           4. No
         Esc to cancel · Tab to amend
        """
    }

    /// Claude Code 2.1.328's approval screen, as read live (verify/push-matrix-terminal-questions.md).
    nonisolated static var screen: String { MainActor.assumeIsolated { screen() } }

    static func make(rows: [String]) -> (FeedStore, TerminalFeed, TerminalQuestionFeedTests.Daemon) {
        let daemon = TerminalQuestionFeedTests.Daemon()
        daemon.rows = rows
        daemon.screen = screen
        let (store, feed) = TerminalQuestionFeedTests.make(daemon)
        return (store, feed, daemon)
    }

    @Test func theApprovalShowsAsAnAllowDenyCardWithItsCommand() async {
        let (store, feed, daemon) = Self.make(rows: [Self.row()])
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        let item = store.item(id: "term-mac-ntf_7")
        guard case .permission(let request) = item?.kind else {
            Issue.record("not a permission card: \(String(describing: item?.kind))")
            return
        }
        #expect(request.toolCall.command == "mkdir -p out && touch out/a.txt")
        #expect(request.phoneOptions.map(\.name) == ["Allow once", "Deny"])
        #expect(item?.markdown == "**Wants to use Bash**\n\nCreate the out folder")
        #expect(item?.opensTerminal == true)
        #expect(item?.needsYou == true)
        // The agent moved on (answered on the Mac): the card closes, its buttons go.
        daemon.rows = [Self.row(approval: nil)]
        await feed.refresh()
        #expect(store.item(id: "term-mac-ntf_7")?.resolution == "Answered in the terminal")
        #expect(store.item(id: "term-mac-ntf_7")?.needsYou == false)
    }

    @Test func allowTypesOneAndDenyEscapeOnlyWhileTheTerminalShowsTheApproval() async throws {
        let (store, feed, daemon) = Self.make(rows: [Self.row()])
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        guard let item = store.item(id: "term-mac-ntf_7"), case .permission(let request) = item.kind else {
            Issue.record("no permission card")
            return
        }
        try await feed.respond(item, request: request, option: TerminalApproval.allowOnce)
        #expect(daemon.reads == 1)
        #expect(daemon.typed.map(\.0) == [1])
        #expect(daemon.typed.map(\.1) == ["1"])
        // A shell, another approval in the dialog, or this card's command only in the transcript
        // above a newer approval's dialog (a stale card): nothing is typed, and the card says why.
        let stale = Self.screen(command: "rm -rf /tmp/other", transcript: "mkdir -p out && touch out/a.txt")
        for screen in ["$ ", Self.screen(command: "rm -rf /tmp/other"), stale] {
            daemon.typed = []
            daemon.screen = screen
            await #expect(throws: TerminalFeed.QuestionRefused.self) {
                try await feed.respond(item, request: request, option: TerminalApproval.allowOnce)
            }
            #expect(daemon.typed.isEmpty)
        }
        daemon.screen = Self.screen
        try await feed.respond(item, request: request, option: TerminalApproval.deny)
        #expect(daemon.typed.map(\.1) == ["\u{1b}"])
        // The Mac's ledger no longer carries it (answered there): nothing is typed, even though
        // this phone's last read still showed it and the screen still shows a matching dialog.
        daemon.typed = []
        daemon.rows = [Self.row(approval: nil)]
        await #expect(throws: TerminalFeed.QuestionRefused.self) {
            try await feed.respond(item, request: request, option: TerminalApproval.allowOnce)
        }
        #expect(daemon.typed.isEmpty)
    }

    /// An approval its dialog cannot be told by (no command, no file) keeps "Answer in Terminal";
    /// a file approval is told by its file name, as Claude Code shows it.
    @Test func onlyAnApprovalItsDialogNamesGetsButtons() async {
        let mcp = #"{"harness":"claude","tool":"mcp__linear__create_issue","description":"File the bug"}"#
        let (store, feed, _) = Self.make(rows: [Self.row(approval: mcp)])
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        #expect(store.item(id: "term-mac-ntf_7")?.kind == .needsInput)
        let write = TerminalApproval(tool: "Write", target: "/Users/me/src/notes/todo.txt")
        #expect(TerminalApprovalKeys.subject(write) == "todo.txt")
        #expect(TerminalApprovalKeys.subject(TerminalApproval(tool: "WebFetch", target: "https://example.com/a")) == nil)
    }

    /// The ledger read made for the answer fails (or would have been coalesced into another read
    /// still in flight): nothing is typed on the strength of this phone's last read.
    @Test func aFailedLedgerReadTypesNothing() async {
        let (store, feed, daemon) = Self.make(rows: [Self.row()])
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        guard let item = store.item(id: "term-mac-ntf_7"), case .permission(let request) = item.kind else {
            Issue.record("no permission card")
            return
        }
        struct Down: Error {}
        feed.request = { command, params, _ in
            if command == "list-notifications" { throw Down() }
            return daemon.respond(command, params)
        }
        await #expect(throws: TerminalFeed.QuestionRefused.self) {
            try await feed.respond(item, request: request, option: TerminalApproval.allowOnce)
        }
        #expect(daemon.typed.isEmpty)
        #expect(daemon.reads == 0)
    }

    /// Only this approval's own dialog, at the bottom of the screen, passes: not a newer command
    /// that starts the same way, not a Bash dialog that mentions a stale Write card's file, not
    /// text the agent wrote that looks like a dialog.
    @Test func onlyThisApprovalsOwnDialogPasses() {
        let build = TerminalApproval(tool: "Bash", command: "cd /Users/me/projects/website && npm run build")
        func dialog(_ head: String, ask: String = "Do you want to proceed?") -> String {
            "\(Self.rule)\n Bash command\n \(head)\n \(ask)\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend"
        }
        #expect(TerminalApprovalKeys.screenShows(dialog("cd /Users/me/projects/website && npm run build"), approval: build))
        // Wrapped mid-word on a narrow terminal: still this command.
        #expect(TerminalApprovalKeys.screenShows(dialog("cd /Users/me/projects/web\n site && npm run build"), approval: build))
        #expect(!TerminalApprovalKeys.screenShows(dialog("cd /Users/me/projects/website && npm run deploy"), approval: build))
        let write = TerminalApproval(tool: "Write", target: "/Users/me/src/README.md")
        #expect(TerminalApprovalKeys.screenShows(dialog("README.md", ask: "Do you want to create README.md?"), approval: write))
        #expect(!TerminalApprovalKeys.screenShows(dialog("cat README.md"), approval: write))
        // The agent's own words above its prompt, not a dialog: no "Esc to cancel" at the bottom.
        let lookalike = dialog("cd /Users/me/projects/website && npm run build") + "\n\n⏺ Done.\n❯ "
        #expect(!TerminalApprovalKeys.screenShows(lookalike, approval: build))
    }
}
