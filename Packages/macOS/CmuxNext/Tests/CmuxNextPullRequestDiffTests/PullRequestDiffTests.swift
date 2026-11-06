import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextPullRequestDiff

/// A pull request's View diff: which links are a pull request's (only a github.com one), which of
/// them is its Files tab, and the diff opened from it, else its web page.
@MainActor
@Suite
struct PullRequestDiffTests {
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    nonisolated private static let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"

    @Test func onlyAGitHubPullRequestLinkIsTaken() {
        let link = GitHubLink(URL(string: "https://github.com/manaflow-ai/cmux/pull/36002/files")!)
        #expect(link?.url == Self.pull)
        #expect(link?.reference == "manaflow-ai/cmux#36002")
        // Only the Files tab opens the diff; the plain link opens github.com.
        #expect(link?.files == true)
        #expect(link?.filesURL.absoluteString == "https://github.com/manaflow-ai/cmux/pull/36002/files")
        #expect(GitHubLink(Self.pull)?.files == false)
        #expect(GitHubLink(URL(string: "https://github.com/manaflow-ai/cmux/pull/36002/commits")!)?.files == false)
        for other in ["https://github.com/manaflow-ai/cmux/issues/1", "https://github.com/manaflow-ai/cmux/pull/1#issuecomment-2",
                      "https://github.com/manaflow-ai/cmux/pull/1?w=1", "https://gitlab.com/a/b/pull/1", "http://github.com/a/b/pull/1",
                      "https://github.com/manaflow-ai/cmux/commit/abc"] {
            #expect(GitHubLink(URL(string: other)!) == nil, "\(other)")
        }
    }

    /// A GitHub page tab saved before the page was removed (cmux#37219) reopens as its pull request's web page.
    @Test func aSavedPageRouteNamesItsPullRequest() {
        #expect(GitHubLink(pageRoute: "#/pull?url=" + Self.pull.absoluteString)?.url == Self.pull)
        #expect(GitHubLink(pageRoute: "#/pull?url=https%3A%2F%2Fgithub.com%2Fmanaflow-ai%2Fcmux%2Fpull%2F36002")?.url == Self.pull)
        for other in [nil, "", "#/pull", "#/pull?url=http://github.com/a/b/pull/1", "#/pull?url=https://example.com/a/b/pull/1",
                      "#/pull?other=https://github.com/a/b/pull/1", "#/pull?url=file:///etc/passwd"] {
            #expect(GitHubLink(pageRoute: other) == nil, "\(other ?? "nil")")
        }
    }

    @Test func aFilesLinkOpensItsDiffElseItsWebPage() async throws {
        let link = try #require(GitHubLink(URL(string: Self.pull.absoluteString + "/files")!))
        for (answer, opens) in [(Self.patch as String?, "diff"), (nil, "web"), ("not a diff", "web")] {
            let opened: (String, String) = await withCheckedContinuation { done in
                PullRequestDiff(local: nil, read: { _ in answer }).open(link, openDiff: { done.resume(returning: ("diff", $0)) },
                                                                       openWeb: { done.resume(returning: ("web", $0.absoluteString)) })
            }
            #expect(opened.0 == opens)
            #expect(opened.1 == (opens == "diff" ? Self.patch : Self.pull.absoluteString + "/files"))
        }
    }
}
