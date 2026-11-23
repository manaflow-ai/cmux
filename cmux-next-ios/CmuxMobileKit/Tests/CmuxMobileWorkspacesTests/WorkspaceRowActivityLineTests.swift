#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A workspace row's second line says what its chat did or is doing (manaflow-ai/cmux#51332).
/// Before, every row read "Done · Claude-sr2: Fix https://github.com/manaflow-ai/…": the harness
/// profile and the chat's first prompt, under a "Done" that said nothing.
@MainActor
@Suite struct WorkspaceRowActivityLineTests {
    static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/51400")!

    static func workspace(_ activity: ChatActivity?, waiting: WorkspaceTab.WaitingFor? = nil,
                          status: WorkspaceTab.AgentStatus? = nil) -> Workspace {
        var tab = WorkspaceTab(id: "t1", kind: .agent, title: "Fix https://github.com/manaflow-ai/cmux/issues/51332 in cmux NEXT",
                               harness: "claude-sr2", agentStatus: status, waitingFor: waiting)
        tab.activity = activity
        return Workspace(id: "ws", macID: "mac", title: "feed", directory: "~/cmux", branch: "ios-feed", tabs: [tab],
                         lastActivityAt: Date(timeIntervalSince1970: 1_000))
    }

    func line(_ workspace: Workspace, _ status: WorkspaceStatus) -> String {
        StatusLine.summary(workspace, status: status, macName: nil).words.joined(separator: " · ")
    }

    @Test func aFinishedChatSaysWhatItDidNotDone() {
        let ws = Self.workspace(ChatActivity(lastLine: "Opened the PR and the dev build is up."))
        #expect(line(ws, .done) == "Opened the PR and the dev build is up.")
        #expect(!line(ws, .done).contains("Claude-sr2"))
        #expect(!line(ws, .done).contains("Done"))
    }

    @Test func aPullRequestShowsItsRealState() {
        func pull(_ state: PullRequestSummary.State?, _ checks: PullRequestSummary.Checks?, _ mergeable: Bool? = nil) -> Workspace {
            Self.workspace(ChatActivity(lastLine: "x", pullRequest: PullRequestSummary(url: Self.pull, number: 51400, title: "Feed cards",
                                                                                       state: state, checks: checks, mergeable: mergeable)))
        }
        #expect(line(pull(.merged, .passing), .done) == "Merged · #51400 Feed cards")
        #expect(line(pull(.open, .failing), .done) == "PR #51400 open · Checks failing")
        #expect(line(pull(.open, .passing, true), .idle) == "PR #51400 open · Ready to merge")
        #expect(line(pull(.open, .pending), .done) == "PR #51400 open · Checks running")
        #expect(line(pull(nil, nil), .done) == "PR #51400 open · Feed cards")
        #expect(StatusLine.summary(pull(.open, .failing), status: .done, macName: nil).tone == .failure)
    }

    @Test func aFailedTurnSaysFailed() {
        let ws = Self.workspace(ChatActivity(lastLine: "The build broke on cmux10s.", failed: true))
        #expect(line(ws, .done) == "Failed · The build broke on cmux10s.")
    }

    @Test func workingAndNeedsYouDropTheAgentsName() {
        let working = Self.workspace(ChatActivity(lastLine: "Reading the build log"), status: .working)
        #expect(line(working, .working) == "Working · Reading the build log")
        let waiting = Self.workspace(nil, waiting: .permission, status: .waiting)
        #expect(line(waiting, .needsYou).hasPrefix("Needs you · Asking permission"))
        #expect(!line(waiting, .needsYou).contains("Claude-sr2"))
        #expect(!line(waiting, .needsYou).contains("Claude is"))
    }

    @Test func anIdleRowWithoutNewsShowsItsPlace() {
        #expect(line(Self.workspace(nil), .idle) == "ios-feed")
        #expect(StatusLine.words(Self.workspace(nil), status: .idle, macName: nil) == ["idle", "ios-feed"])
    }
}
#endif
