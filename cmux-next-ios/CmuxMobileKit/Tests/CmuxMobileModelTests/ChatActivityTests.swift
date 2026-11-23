import Foundation
import Testing
@testable import CmuxMobileModel

/// What a workspace row and a Feed card say a chat did (manaflow-ai/cmux#51332): its reply's
/// first line, its pull request, its dev build; never the harness profile ("Claude-sr2").
@Suite struct ChatActivityTests {
    @Test func theFirstLineDropsMarkdown() {
        #expect(ChatActivity.firstLine("## Done\n\nmore") == "Done")
        #expect(ChatActivity.firstLine("**Fixed** the [login](https://x.y) redirect.") == "Fixed the login redirect.")
        #expect(ChatActivity.firstLine("- `cargo test` passes") == "cargo test passes")
        #expect(ChatActivity.firstLine("   \n\n") == nil)
        let long = String(repeating: "word ", count: 60)
        #expect((ChatActivity.firstLine(long)?.count ?? 0) <= 140)
    }

    @Test func pullRequestLinksAreRead() {
        let text = "Opened https://github.com/manaflow-ai/cmux/pull/51400 and see https://github.com/manaflow-ai/cmux/pull/51400/files"
        #expect(ChatActivity.pullRequests(in: text).map(\.number) == [51400])
        #expect(PullRequestSummary(link: "https://github.com/manaflow-ai/cmux/pull/12?tab=files")?.url.absoluteString
            == "https://github.com/manaflow-ai/cmux/pull/12")
        #expect(PullRequestSummary(link: "https://example.com/o/r/pull/1") == nil)
        #expect(PullRequestSummary(link: "https://github.com/o/r/issues/1") == nil)
    }

    @Test func aDevBuildTagIsRead() {
        #expect(ChatActivity.devBuildTag(in: "Tag Opener http://127.0.0.1:17320/feed-threads") == "feed-threads")
        #expect(ChatActivity.devBuildTag(in: "Dev build `ios-feed` is ready") == "ios-feed")
        #expect(ChatActivity.devBuildTag(in: "built with --tag wg-1") == "wg-1")
        #expect(ChatActivity.devBuildTag(in: "nothing to see") == nil)
    }

    @Test func harnessProfilesNameTheirAgent() {
        #expect(HarnessName.display("claude-sr2") == "Claude")
        #expect(HarnessName.display("claude") == "Claude")
        #expect(HarnessName.display("codex") == "Codex")
        #expect(HarnessName.display("opencode") == "OpenCode")
        #expect(HarnessName.display(nil) == "Agent")
        #expect(WorkspaceTab(id: "t", kind: .agent, title: "x", harness: "claude-sr2").agentName == "Claude")
    }

    @Test func mergeIsOfferedOnlyWhenReady() throws {
        let url = try #require(URL(string: "https://github.com/o/r/pull/1"))
        #expect(PullRequestSummary(url: url, number: 1, state: .open, checks: .passing, mergeable: true).canMerge)
        #expect(!PullRequestSummary(url: url, number: 1, state: .open, checks: .pending).canMerge)
        #expect(!PullRequestSummary(url: url, number: 1, state: .open, checks: .passing, mergeable: false).canMerge)
        #expect(!PullRequestSummary(url: url, number: 1, state: .draft, checks: .passing).canMerge)
        #expect(!PullRequestSummary(url: url, number: 1, state: .merged).canMerge)
    }

    @Test func aSavedTabWithoutActivityStillLoads() throws {
        let old = #"{"id":"t","kind":"agent","title":"x","harness":"claude"}"#
        let tab = try JSONDecoder().decode(WorkspaceTab.self, from: Data(old.utf8))
        #expect(tab.activity == nil)
    }
}
