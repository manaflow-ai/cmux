import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextGitHubViewer

/// The GitHub page's app side: which links it takes (a github.com pull request, nothing else), its
/// route, the diff it reads once per pull request and opens only on a person's click, and the link
/// card ops it shares with the agent page.
@MainActor
@Suite
struct GitHubPageProviderTests {
    private static let page = PageCallContext(page: "cmux.github")
    private static let click = PageCallContext(page: "cmux.github", userGesture: true, gestureEvent: 1)
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    private static let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"

    /// Counts diff reads; answers `text`.
    private final class Reads: @unchecked Sendable { // crash-allow: test counter touched only on the main actor
        var count = 0
    }

    /// A cache whose gh is missing: every read ends at once with no answer.
    private static func cache() -> AgentReplyPullRequests {
        AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: "/nonexistent/gh", environment: [:]))
    }

    @Test func onlyAGitHubPullRequestLinkIsTaken() {
        let link = GitHubLink(URL(string: "https://github.com/manaflow-ai/cmux/pull/36002/files")!)
        #expect(link?.url == Self.pull)
        #expect(link?.reference == "manaflow-ai/cmux#36002")
        for other in ["https://github.com/manaflow-ai/cmux/issues/1", "https://github.com/manaflow-ai/cmux/pull/1#issuecomment-2",
                      "https://github.com/manaflow-ai/cmux/pull/1?w=1", "https://gitlab.com/a/b/pull/1", "http://github.com/a/b/pull/1",
                      "https://github.com/manaflow-ai/cmux/commit/abc"] {
            #expect(GitHubLink(URL(string: other)!) == nil, "\(other)")
        }
    }

    @Test func theRouteNamesThePullRequestAndReadsBack() throws {
        let link = try #require(GitHubLink(Self.pull))
        #expect(link.route == "#/pull?url=https://github.com/manaflow-ai/cmux/pull/36002")
        #expect(GitHubLink(route: link.route) == link)
        #expect(GitHubLink(route: "#/pull?url=https://example.com/a/b/pull/1") == nil)
        #expect(GitHubLink(route: "#/other") == nil)
    }

    @Test func theDiffIsReadOnceAndOpensOnlyOnAClick() async throws {
        let reads = Reads()
        var opened: [(String, String, String?)] = []
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in
            await MainActor.run { reads.count += 1 }
            return Self.patch
        }, openWeb: { _, _ in false }, openDiff: { text, link, file, _ in
            opened.append((text, link.reference, file))
            return true
        })
        // Asking about the pull request starts the diff read; asking again does not start another.
        _ = try await provider.call("cmux.github.pr.inspect", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
        _ = try await provider.call("cmux.github.pr.inspect", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
        // A call with no click opens nothing.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
        }
        let reply = try await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString), "file": "x"],
                                            context: Self.click)
        #expect(reply["opened"]?.boolValue == true)
        #expect(reads.count == 1)
        #expect(opened.count == 1)
        #expect(opened.first?.1 == "manaflow-ai/cmux#36002")
        #expect(opened.first?.2 == "x")
        // The same click is spent: a second call with it opens nothing.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString)], context: Self.click)
        }
    }

    @Test func aReadStartedBeforeTheCacheHadThePullRequestIsNotReadAgain() async throws {
        let reads = Reads(), cache = Self.cache()
        let provider = GitHubPageProvider(cache: cache, diffReader: { _ in
            await MainActor.run { reads.count += 1 }
            return Self.patch
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in true })
        // The first ask finds the cache cold; the next finds the pull request with its updatedAt.
        _ = try await provider.call("cmux.github.pr.inspect", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
        let view = #"{"url": "\#(Self.pull.absoluteString)", "number": 36002, "updatedAt": "2026-11-05T10:00:00Z"}"#
        cache.seed(try #require(AgentPanePullRequest(ghView: Data(view.utf8))), for: Self.pull)
        _ = try await provider.call("cmux.github.pr.inspect", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
        _ = try await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString)], context: Self.click)
        #expect(reads.count == 1)
    }

    @Test func aFailedDiffReadSaysWhyAndIsReadAgainNextTime() async throws {
        let reads = Reads()
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in
            await MainActor.run { reads.count += 1 }
            return nil
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in true })
        do {
            _ = try await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString)], context: Self.click)
            Issue.record("a failed read opened a diff")
        } catch let error as PageError {
            #expect(error.code == "cmux.github.diff_unavailable")
        }
        let next = PageCallContext(page: "cmux.github", userGesture: true, gestureEvent: 2)
        _ = try? await provider.call("cmux.github.diff.open", params: ["url": .string(Self.pull.absoluteString)], context: next)
        #expect(reads.count == 2)
    }

    @Test func otherOpsAndLinksAreRefused() async {
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in nil }, openWeb: { _, _ in true }, openDiff: { _, _, _, _ in true })
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.link.openPath", params: ["path": "/etc/passwd"], context: Self.click)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.diff.open", params: ["url": "https://github.com/a/b/issues/1"], context: Self.click)
        }
        // Open on GitHub takes only https.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.browser.openIn", params: ["url": "http://github.com/a/b/pull/1", "browserId": "cmux"],
                                        context: Self.click)
        }
    }
}
