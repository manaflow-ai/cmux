import Foundation
import Testing
@testable import CmuxNextGitHubViewer

/// A pull request's Files link: which links it takes (a github.com pull request, nothing else) and
/// what its click opens (the diff, else the Files tab's web page).
@MainActor
@Suite
struct GitHubPullRequestDiffTests {
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    nonisolated private static let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"

    @Test func onlyAGitHubPullRequestLinkIsTaken() {
        let link = GitHubLink(URL(string: "https://github.com/manaflow-ai/cmux/pull/36002/files")!)
        #expect(link?.url == Self.pull)
        #expect(link?.reference == "manaflow-ai/cmux#36002")
        // The Files tab opens the diff itself; the plain link opens its web page.
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

    /// A GitHub page tab saved before the page was retired (#36101) names its pull request in its route.
    @Test func aSavedPageRouteNamesItsPullRequest() {
        #expect(GitHubLink(route: "#/pull?url=https://github.com/manaflow-ai/cmux/pull/36002")?.url == Self.pull)
        #expect(GitHubLink(route: "#/pull?url=https%3A%2F%2Fgithub.com%2Fmanaflow-ai%2Fcmux%2Fpull%2F36002")?.reference == "manaflow-ai/cmux#36002")
        for other in ["", "#/other", "#/pull", "#/pull?url=https://example.com/a/b/pull/1", "#/pull?url=https://github.com/a/b/issues/1"] {
            #expect(GitHubLink(route: other) == nil, "\(other)")
        }
    }

    @Test func aFilesLinkOpensItsDiffElseItsWebPage() async throws {
        let link = try #require(GitHubLink(URL(string: Self.pull.absoluteString + "/files")!))
        for (answer, opens) in [(Self.patch as String?, "diff"), (nil, "web"), ("not a diff", "web")] {
            let opened: (String, String) = await withCheckedContinuation { done in
                GitHubPullRequestDiff.openFiles(link, localDiff: nil, read: { _ in answer }, openDiff: { done.resume(returning: ("diff", $0)) },
                                                openWeb: { done.resume(returning: ("web", $0.absoluteString)) })
            }
            #expect(opened.0 == opens)
            #expect(opened.1 == (opens == "diff" ? Self.patch : Self.pull.absoluteString + "/files"))
        }
    }
}
